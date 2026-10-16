import Foundation
import AttentionDomain
import HarklightNativeRelay
import Network
import Security
import XCTest
@testable import AttentionClientDuoPrototype

/// Actual pinned TLS exercises certificate-free enrollment and the explicit
/// identity proof required for own-device removal. The iOS listener cannot
/// request an optional certificate; that server seam needs server integration.
@MainActor
final class NativeGuidedTLSTests: XCTestCase {
    func testAuthenticatedRelayRefusesToFollowAnotherEndpoint() async throws {
        let namespace = "Harklight.relay-redirect-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let target = try LocalEnrollmentTLS(expectedDevice: identity.deviceID)
        defer { target.close() }
        let targetPort = try await target.start()
        let targetURL = try XCTUnwrap(URL(string: "wss://localhost:\(targetPort)/relay"))
        let original = try LocalEnrollmentTLS(expectedDevice: identity.deviceID, redirectTo: targetURL)
        defer { original.close() }
        let port = try await original.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
            deviceID: ExactText(identity.deviceID)), transportMode: .relay)
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: original.rootDER)
        do {
            try await session.resync(Data("{}\n".utf8)) { _ in }
            XCTFail("A redirect cannot establish the authenticated relay")
        } catch {}
        await session.close()
        XCTAssertTrue(original.receivedRequest, "The original pinned relay received the connection")
        XCTAssertFalse(target.receivedRequest, "The authenticated request must not reach a redirected endpoint")
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

    func testOversizedInvitationServerResponseIsStoppedFromItsAdvertisedLength() async throws {
        try await rejectOversizedResponse(advertiseSize: true)
    }

    func testOversizedInvitationServerStreamIsStoppedWithoutAContentLength() async throws {
        try await rejectOversizedResponse(advertiseSize: false)
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

    func testForegroundConnectDeadlineClosesOneSessionAndFencesLateSuccessWithoutChangingSavedState() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"), deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("saved"))
        let payload = try JSONValue.parse(Data(#"{"title":"Saved request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))), context: context)
        let binding = ConversationBinding(request: key, revision: 1)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep this draft")), context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        _ = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                         inputs: [.compatibilityValue(action: ExactText("got-it"))]))
        let before = try XCTUnwrap(persistence.load(identity: identity))
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[key]?.drafts[1]?.text,
                       ExactText("Keep this draft"))

        let deadline = ForegroundConnectDeadline()
        let transportAttemptID = UUID()
        deadline.beginSession(transportAttemptID: transportAttemptID)
        deadline.observe(.clientIdentityOffered, transportAttemptID: transportAttemptID)
        let sessionID = UUID()
        var closedSessions: [UUID] = []
        var lateCompletion: CheckedContinuation<Bool, Never>?
        var updates: [NativeForegroundConnectProgress] = []
        let operationStarted = AsyncTestSignal()
        let run = Task { @MainActor in
            await deadline.run(deadline: .milliseconds(100), operation: {
                await operationStarted.signal()
                return await withCheckedContinuation { continuation in lateCompletion = continuation }
            }, onTimeout: {
                closedSessions.append(sessionID)
            }, onProgress: { progress in
                updates.append(progress)
            })
        }
        await operationStarted.wait()
        let result = await run.value

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertFalse(result.webSocketOpenObserved)
        XCTAssertTrue(result.message.contains("No WebSocket-open event arrived"))
        XCTAssertTrue(result.message.contains("cannot distinguish a TLS failure from a WebSocket-upgrade timeout"))
        XCTAssertEqual(closedSessions, [sessionID], "Timeout closes only the session captured by this attempt.")

        // Neither a stale open callback nor a late successful operation may
        // turn the timed-out attempt into foreground confirmation.
        deadline.observe(.webSocketOpened, transportAttemptID: transportAttemptID)
        lateCompletion?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(deadline.progress.outcome, .timedOut)
        XCTAssertFalse(updates.contains(where: { $0.outcome == .confirmed }))
        XCTAssertEqual(try persistence.load(identity: identity), before,
                       "Timeout preserves the saved request, answer outbox, and conversation draft byte-for-byte.")
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[key]?.drafts[1]?.text,
                       ExactText("Keep this draft"))
    }

    func testForegroundDiagnosticShareIncludesExactBuildPhaseReceiptAndNoAnswerContent() throws {
        let operationID = UUID()
        let answer = try JSONValue.parse(Data(#""PRIVATE-ANSWER-SENTINEL""#.utf8))
        let operation = try JSONValue.parse(Data(#"{"type":"answer","op_id":"\#(operationID.uuidString.lowercased())","answer":"PRIVATE-ANSWER-SENTINEL"}"#.utf8))
        let submission = Submission(requestKey: RequestKey(accountScope: ExactText("private-account"),
                                                            senderID: ExactText("sender-17"),
                                                            messageID: ExactText("message-29")),
                                    answer: answer, intentID: UUID(), operationID: operationID,
                                    operation: operation,
                                    descriptorFingerprint: "descriptor-fingerprint",
                                    contentFingerprint: "content-fingerprint",
                                    requestRevision: 4)
        let progress = NativeForegroundConnectProgress(lastConfirmedStage: .nativeSyncResynced,
                                                        webSocketOpenObserved: true, issue: nil,
                                                        outcome: .timedOut, attemptID: UUID(),
                                                        failureClass: .foregroundDeadline)
        let diagnostic = NativeForegroundConnectDiagnostic(
            progress: progress,
            operationSnapshot: NativeForegroundOperationSnapshot(available: true,
                operations: [NativeForegroundOperationDiagnostic(submission: submission,
                                                                  receiptState: "pending_unconfirmed")]),
            appVersion: "4.8.2", buildNumber: "1087",
            executableSHA256: String(repeating: "a", count: 64))

        XCTAssertTrue(diagnostic.shareText.contains("app_version=4.8.2"))
        XCTAssertTrue(diagnostic.shareText.contains("app_build=1087"))
        XCTAssertTrue(diagnostic.shareText.contains("app_executable_sha256=\(String(repeating: "a", count: 64))"))
        XCTAssertTrue(diagnostic.shareText.contains("attempt_id=\(progress.attemptID!.uuidString.lowercased())"))
        XCTAssertTrue(diagnostic.shareText.contains("last_confirmed_phase=native_sync_resynced"))
        XCTAssertTrue(diagnostic.shareText.contains("error_class=foreground_deadline"))
        XCTAssertTrue(diagnostic.shareText.contains("operation_id=\(operationID.uuidString.lowercased())"))
        XCTAssertTrue(diagnostic.shareText.contains("sender_id=sender-17 message_id=message-29 request_revision=4"))
        XCTAssertTrue(diagnostic.shareText.contains("receipt_state=pending_unconfirmed"))
        XCTAssertFalse(diagnostic.shareText.contains("PRIVATE-ANSWER-SENTINEL"),
                       "The allowlisted report must not serialize answer or operation payload content.")
        XCTAssertFalse(diagnostic.shareText.contains("private-account"),
                       "The report must not include the account/person identifier.")

        let bundleDiagnostic = NativeForegroundConnectDiagnostic(
            progress: progress,
            operationSnapshot: .unavailable,
            bundle: .main)
        XCTAssertEqual(bundleDiagnostic.executableSHA256.count, 64)
        XCTAssertTrue(bundleDiagnostic.executableSHA256.allSatisfy(\.isHexDigit))
        XCTAssertTrue(bundleDiagnostic.shareText.contains("app_executable_sha256=\(bundleDiagnostic.executableSHA256)"))
    }

    func testUncertainRetrySendsOnlyTheSameSavedOperationAndBinding() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"), deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender-original"),
                             messageID: ExactText("message-original"))
        let payload = try JSONValue.parse(Data(#"{"title":"Saved request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"approve","label":"Approve","kind":"value","value":"approve"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let originalReceipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
                                                            intentID: UUID(),
                                                            inputs: [.compatibilityValue(action: ExactText("approve"))]))
        let original = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        XCTAssertEqual(originalReceipt.opID, original.operationID)
        XCTAssertEqual(original.requestRevision, 1)

        let session = ForegroundProgressRelaySession(identity: identity, store: store, context: context)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let firstAttempt = try await core.sendPendingOriginalOperations()
        let secondAttempt = try await core.sendPendingOriginalOperations()
        XCTAssertEqual(firstAttempt, 1)
        XCTAssertEqual(secondAttempt, 1)

        let sends = session.originalOperationRecorder.snapshot()
        XCTAssertEqual(sends.operationIDs, [original.operationID, original.operationID])
        XCTAssertEqual(sends.frames, [original.wireFrame, original.wireFrame])
        let retained = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        XCTAssertEqual(retained.operationID, original.operationID)
        XCTAssertEqual(retained.requestKey, original.requestKey)
        XCTAssertEqual(retained.requestRevision, original.requestRevision)
        XCTAssertEqual(retained.answer, original.answer)
        XCTAssertEqual(retained.operation, original.operation)
    }

    func testNativeSyncReportsDurableResyncBeforeItsAcknowledgement() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"), deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let session = ForegroundProgressRelaySession(identity: identity, store: store, context: context)
        let events = RelayProgressRecorder()
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onProgress: { events.append($0) })

        let high = try await core.resyncAndDrainOutbox()

        XCTAssertEqual(high, 1)
        XCTAssertEqual(session.cursorAtAcknowledgement, 1,
                       "The event cursor must be durable before the ACK exchange begins.")
        XCTAssertEqual(events.snapshot(), [.nativeSyncReplayRequested, .nativeSyncResynced, .nativeSyncAcknowledged])

        let progress = ForegroundConnectDeadline()
        let transportAttemptID = UUID()
        progress.beginSession(transportAttemptID: transportAttemptID)
        progress.observe(.serverTrustValidated, transportAttemptID: transportAttemptID)
        XCTAssertEqual(progress.progress.lastConfirmedStage, .serverTrustValidated)
        progress.observe(.clientIdentityOffered, transportAttemptID: transportAttemptID)
        XCTAssertTrue(progress.progress.message.contains("server acceptance is not known yet"))
        progress.observe(.webSocketOpened, transportAttemptID: transportAttemptID)
        XCTAssertTrue(progress.progress.webSocketOpenObserved)
        progress.observe(.relayAdmitted, transportAttemptID: transportAttemptID)
        XCTAssertEqual(progress.progress.lastConfirmedStage, .relayAdmitted)
        progress.observe(.nativeSyncReplayRequested, transportAttemptID: transportAttemptID)
        XCTAssertEqual(progress.progress.lastConfirmedStage, .relayAdmitted,
                       "A local replay request is not a remotely confirmed phase.")
        XCTAssertTrue(progress.progress.nativeSyncReplayRequested)
        progress.observe(.nativeSyncResynced, transportAttemptID: transportAttemptID)
        progress.observe(.nativeSyncAcknowledged, transportAttemptID: transportAttemptID)
        XCTAssertEqual(progress.progress.lastConfirmedStage, .nativeSyncAcknowledged)

        let rejectedTrust = ForegroundConnectDeadline()
        let rejectedTrustTransportID = UUID()
        rejectedTrust.beginSession(transportAttemptID: rejectedTrustTransportID)
        rejectedTrust.observe(.serverTrustRejected, transportAttemptID: rejectedTrustTransportID)
        XCTAssertEqual(rejectedTrust.progress.issue, .serverTrustRejected)
        XCTAssertTrue(rejectedTrust.progress.message.contains("did not pass the saved host and CA check"))

        let rejectedIdentity = ForegroundConnectDeadline()
        let rejectedIdentityTransportID = UUID()
        rejectedIdentity.beginSession(transportAttemptID: rejectedIdentityTransportID)
        rejectedIdentity.observe(.clientIdentityChallengeRejected, transportAttemptID: rejectedIdentityTransportID)
        XCTAssertEqual(rejectedIdentity.progress.issue, .clientIdentityChallengeRejected)
        XCTAssertTrue(rejectedIdentity.progress.message.contains("could not offer its identity to the saved relay host"))
    }

    func testReplacementTransportHasFreshPhasesAndKeepsOnlyPriorTransportSummary() async throws {
        let deadline = ForegroundConnectDeadline()
        let firstTransportID = UUID()
        deadline.beginSession(transportAttemptID: firstTransportID)
        let operationStarted = AsyncTestSignal()
        var finishOperation: CheckedContinuation<Bool, Never>?
        let run = Task { @MainActor in
            await deadline.run(deadline: .seconds(3), operation: {
                await operationStarted.signal()
                return await withCheckedContinuation { finishOperation = $0 }
            }, onTimeout: {}, onProgress: { _ in })
        }
        await operationStarted.wait()

        deadline.observe(.serverTrustValidated, transportAttemptID: firstTransportID)
        deadline.observe(.clientIdentityOffered, transportAttemptID: firstTransportID)
        deadline.observe(.webSocketOpened, transportAttemptID: firstTransportID)
        deadline.observe(.relayAdmitted, transportAttemptID: firstTransportID)
        deadline.observe(.nativeSyncReplayRequested, transportAttemptID: firstTransportID)
        deadline.observe(.nativeSyncResynced, transportAttemptID: firstTransportID)
        deadline.observe(.nativeSyncAcknowledged, transportAttemptID: firstTransportID)
        deadline.recordFailure(URLError(.networkConnectionLost))

        let secondTransportID = UUID()
        deadline.beginTransportAttempt(secondTransportID)
        XCTAssertEqual(deadline.progress.transportAttemptID, secondTransportID)
        XCTAssertNil(deadline.progress.lastConfirmedStage)
        XCTAssertFalse(deadline.progress.webSocketOpenObserved)
        XCTAssertFalse(deadline.progress.nativeSyncReplayRequested)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.id, firstTransportID)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.lastConfirmedStage, .nativeSyncAcknowledged)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.failureClass,
                       .urlSession(code: URLError.networkConnectionLost.rawValue))

        // A local replay request cannot become a confirmed phase, and a
        // callback queued by the retired transport cannot contaminate the new one.
        deadline.observe(.nativeSyncReplayRequested, transportAttemptID: secondTransportID)
        XCTAssertNil(deadline.progress.lastConfirmedStage)
        deadline.observe(.webSocketOpened, transportAttemptID: firstTransportID)
        XCTAssertNil(deadline.progress.lastConfirmedStage)
        XCTAssertFalse(deadline.progress.webSocketOpenObserved)
        deadline.observe(.serverTrustValidated, transportAttemptID: secondTransportID)
        XCTAssertEqual(deadline.progress.lastConfirmedStage, .serverTrustValidated,
                       "A later-arriving trust result must not be hidden by the earlier local replay request.")

        let diagnostic = NativeForegroundConnectDiagnostic(progress: deadline.progress,
                                                            operationSnapshot: .unavailable,
                                                            appVersion: "test", buildNumber: "test",
                                                            executableSHA256: "unavailable")
        XCTAssertTrue(diagnostic.shareText.contains("transport_attempt_id=\(secondTransportID.uuidString.lowercased())"))
        XCTAssertTrue(diagnostic.shareText.contains("last_confirmed_phase=server_trust_validated"))
        XCTAssertTrue(diagnostic.shareText.contains("previous_transport_attempt_id=\(firstTransportID.uuidString.lowercased())"))
        XCTAssertTrue(diagnostic.shareText.contains("previous_last_confirmed_phase=native_sync_acknowledged"))
        XCTAssertTrue(diagnostic.shareText.contains("previous_error_class=url_session_error_code_\(URLError.networkConnectionLost.rawValue)"))

        finishOperation?.resume(returning: false)
        let completed = await run.value
        XCTAssertEqual(completed.outcome, .incomplete)
    }

    func testRestoredInboxCanRetryTheSameApprovedIdentityAndTimeoutStopsAutomaticJoinRetry() async throws {
        let establishedService = "Harklight.foreground-established-retry." + UUID().uuidString
        defer { deleteEnrollmentRecord(service: establishedService) }
        let establishedRecord = approvedRecord(foregroundRelayConfirmed: true,
                                               notificationExplanationSeen: true)
        try saveEnrollmentRecord(establishedRecord, service: establishedService)
        let establishedFlow = NativeGuidedJoinCoordinator(
            store: NativeGuidedJoinStore(namespace: establishedService), deviceName: "Test device")
        var establishedConnections: [NativeEnrollmentRecord] = []
        establishedFlow.connectApproved = { record in
            establishedConnections.append(record)
            return establishedConnections.count > 1
        }

        await establishedFlow.restore()
        XCTAssertFalse(establishedFlow.isShowing, "A restored joined account remains in its ordinary inbox while offline.")
        XCTAssertEqual(establishedConnections, [establishedRecord])
        XCTAssertFalse(establishedFlow.shouldAutomaticallyRetry(foregroundOutcome: .timedOut))

        await establishedFlow.retryApprovedConnection()
        XCTAssertEqual(establishedConnections, [establishedRecord, establishedRecord],
                       "The inbox Retry reconnects the exact approved record, not a new join request.")
        XCTAssertEqual(establishedFlow.screen, .connected)
        XCTAssertFalse(establishedFlow.isShowing)

        let firstJoinService = "Harklight.foreground-first-join-retry." + UUID().uuidString
        defer { deleteEnrollmentRecord(service: firstJoinService) }
        let firstJoinRecord = approvedRecord(foregroundRelayConfirmed: false,
                                             notificationExplanationSeen: false)
        try saveEnrollmentRecord(firstJoinRecord, service: firstJoinService)
        let firstJoinFlow = NativeGuidedJoinCoordinator(
            store: NativeGuidedJoinStore(namespace: firstJoinService), deviceName: "Test device")
        var firstJoinConnections = 0
        firstJoinFlow.connectApproved = { _ in
            firstJoinConnections += 1
            return false
        }
        await firstJoinFlow.restore()
        XCTAssertTrue(firstJoinFlow.isShowing)
        XCTAssertEqual(firstJoinFlow.screen, .approvedFinishing)
        XCTAssertEqual(firstJoinConnections, 1)
        let retriedAutomatically = await firstJoinFlow.retryAutomaticallyIfNeeded(foregroundOutcome: .timedOut)
        XCTAssertFalse(retriedAutomatically,
                       "The scene poll must honor the explicit Retry boundary after timeout.")
        XCTAssertEqual(firstJoinConnections, 1,
                       "The actual scene-poll caller must not re-run an approved connection after timeout.")
        XCTAssertFalse(firstJoinFlow.shouldAutomaticallyRetry(foregroundOutcome: .timedOut))
        XCTAssertTrue(firstJoinFlow.shouldAutomaticallyRetry(foregroundOutcome: .incomplete),
                      "Other saved approval checks retain their existing retry behavior.")
    }

    private func approvedRecord(foregroundRelayConfirmed: Bool,
                                notificationExplanationSeen: Bool) -> NativeEnrollmentRecord {
        NativeEnrollmentRecord(host: "relay.example.test", enrollmentPort: 18444, relayPort: 18443,
                               trustedRootDER: Data([1]), identityLabel: "saved-device-identity",
                               deviceLabel: "Saved device", deviceID: "saved-device-id",
                               approvalCode: "ABCDEF2345", statusSecret: String(repeating: "a", count: 64),
                               expiresAt: 1, statusExpiresAt: 2, personID: "saved-person",
                               notificationExplanationSeen: notificationExplanationSeen,
                               foregroundRelayConfirmed: foregroundRelayConfirmed)
    }

    private func saveEnrollmentRecord(_ record: NativeEnrollmentRecord, service: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: "current-installation",
                                    kSecValueData as String: try JSONEncoder().encode(record),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertEqual(SecItemAdd(query as CFDictionary, nil), errSecSuccess)
    }

    private func deleteEnrollmentRecord(service: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    func testStalledForegroundRelayTimesOutClosesOnlyItsSessionAndPreservesSavedState() async throws {
        let namespace = "Harklight.foreground-deadline-test." + UUID().uuidString
        let installation = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: installation.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }

        let server = try LocalEnrollmentTLS(expectedDevice: installation.deviceID, stallRequest: true)
        defer { server.close() }
        let relayPort = try await server.start()
        let relayURL = try XCTUnwrap(URL(string: "wss://localhost:\(relayPort)/relay"))
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("localhost"),
                                       personID: ExactText("local-test-person"),
                                       deviceID: ExactText(installation.deviceID))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let requestKey = RequestKey(accountScope: identity.personID, senderID: ExactText("local-agent"),
                                    messageID: ExactText("saved-before-stall"))
        let payload = try JSONValue.parse(Data(#"{"title":"Saved request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"got-it","label":"Got it","kind":"value","value":"got-it"}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1, body: .delivery(
            StoredRequest(key: requestKey, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("local-session"))),
            context: context)
        let binding = ConversationBinding(request: requestKey, revision: 1)
        try store.saveConversationDraft(ConversationDraft(binding: binding, text: ExactText("Keep this draft")),
                                        context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: requestKey).requests.first?.selector)
        _ = try port.submit(SubmitIntent(context: port.context, selector: selector, intentID: UUID(),
                                         inputs: [.compatibilityValue(action: ExactText("got-it"))]))
        let originalOperation = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        let savedBefore = try XCTUnwrap(persistence.load(identity: identity))
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)

        let lifecycle = NativeRelayLifecycle()
        try await lifecycle.activate(store: store, context: context, relayURL: relayURL,
                                     clientIdentity: installation.value, trustedRootDER: server.rootDER)
        var progressUpdates: [NativeForegroundConnectProgress] = []
        var operationSnapshots: [NativeForegroundOperationSnapshot] = []
        let result = await lifecycle.confirmForegroundProgress(for: context, deadline: .seconds(3)) {
            progressUpdates.append($0)
            operationSnapshots.append(lifecycle.foregroundOperationDiagnostics(for: context))
        }

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.failureClass, .foregroundDeadline)
        XCTAssertNotNil(result.attemptID)
        XCTAssertFalse(result.webSocketOpenObserved)
        XCTAssertTrue(result.message.contains("No WebSocket-open event arrived"))
        let requestReceived = await eventually { server.receivedRequest }
        XCTAssertTrue(requestReceived, "The local TLS fixture must receive the WebSocket request.")
        XCTAssertEqual(server.acceptedConnectionCount, 1)
        let connectionClosed = await eventually { server.clientClosed }
        XCTAssertTrue(connectionClosed, "The timed-out matching relay session must close its local TLS connection.")
        XCTAssertFalse(progressUpdates.contains(where: { $0.outcome == .confirmed }))
        XCTAssertEqual(try persistence.load(identity: identity), savedBefore,
                       "The stalled connection must preserve the approved profile's local state.")
        XCTAssertEqual(try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate().deviceID,
                       installation.deviceID, "The approved device identity remains available after timeout.")
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[requestKey]?.drafts[1]?.text,
                       ExactText("Keep this draft"))
        let operationSnapshot = try XCTUnwrap(operationSnapshots.last)
        XCTAssertTrue(operationSnapshot.available)
        XCTAssertEqual(operationSnapshot.operations.count, 1)
        XCTAssertEqual(operationSnapshot.operations.first?.operationID, originalOperation.operationID)
        XCTAssertEqual(operationSnapshot.operations.first?.senderID, requestKey.senderID.rawValue)
        XCTAssertEqual(operationSnapshot.operations.first?.messageID, requestKey.messageID.rawValue)
        XCTAssertEqual(operationSnapshot.operations.first?.requestRevision, 1)
        XCTAssertEqual(operationSnapshot.operations.first?.receiptState, "pending_unconfirmed")

        let implicitRetry = await lifecycle.refreshFromTrustedRelay()
        XCTAssertFalse(implicitRetry, "A timed-out approved identity waits for the visible, explicit retry action.")
        XCTAssertEqual(server.acceptedConnectionCount, 1, "Background refresh must not silently reopen the timed-out session.")
        await lifecycle.deactivate()
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        for _ in 0..<150 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func rejectOversizedResponse(advertiseSize: Bool) async throws {
        let server = try LocalEnrollmentTLS(expectedDevice: nil,
                                            replyBody: Data(repeating: 120, count: 1024 * 1024),
                                            advertiseSize: advertiseSize)
        defer { server.close() }
        let port = try await server.start()
        let url = try XCTUnwrap(URL(string: "https://localhost:\(port)/enroll"))
        do {
            _ = try await PinnedNativeJoinTransport().request(url, method: "GET", body: nil,
                                                              rootDER: server.rootDER)
            XCTFail("An oversized invitation response must be stopped before joining can continue")
        } catch NativeJoinError.invalidResponse {}
    }
}

private final class LocalEnrollmentTLS: @unchecked Sendable {
    let rootDER: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Harklight.local-enrollment-tls")
    private let replyBody: Data
    private let advertiseSize: Bool
    private let redirectTo: URL?
    private let stallRequest: Bool
    // All connection ownership is serialized on queue, including close().
    private var connections: [NWConnection] = []
    private var requestWasReceived = false
    private var connectionWasClosed = false
    var acceptedConnectionCount: Int { queue.sync { connections.count } }
    var receivedRequest: Bool { queue.sync { requestWasReceived } }
    var clientClosed: Bool { queue.sync { connectionWasClosed } }

    init(expectedDevice: String?, replyBody: Data = Data("{\"state\":\"reachable\"}".utf8),
         advertiseSize: Bool = true, redirectTo: URL? = nil, stallRequest: Bool = false) throws {
        self.replyBody = replyBody
        self.advertiseSize = advertiseSize
        self.redirectTo = redirectTo
        self.stallRequest = stallRequest
        let bundle = Bundle(for: NativeGuidedTLSTests.self)
        guard let certificateURL = bundle.url(forResource: "guided-local-tls", withExtension: "pem"),
              let identityURL = bundle.url(forResource: "guided-local-tls", withExtension: "p12"),
              let root = NativeEnrollmentSettings.certificateDER(from: try String(contentsOf: certificateURL,
                                                                                   encoding: .utf8)) else {
            throw NativeEnrollmentError.invalidIdentity
        }
        rootDER = root
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
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
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
                    let lengthHeader = advertiseSize ? "Content-Length: \(replyBody.count)\r\n" : ""
                    let reply: Data
                    if let redirectTo {
                        reply = Data("HTTP/1.1 302 Found\r\nLocation: \(redirectTo.absoluteString)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    } else {
                        reply = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\(lengthHeader)Connection: close\r\n\r\n".utf8) + replyBody
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

private final class RelayProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [NativeRelayProgressEvent] = []

    func append(_ event: NativeRelayProgressEvent) {
        lock.lock(); defer { lock.unlock() }
        values.append(event)
    }

    func snapshot() -> [NativeRelayProgressEvent] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private final class ForegroundProgressRelaySession: AuthenticatedInstallationSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    private let store: AttentionDomainStore
    private let context: ProfileContext
    private(set) var cursorAtAcknowledgement: UInt64?
    let originalOperationRecorder = OriginalOperationRecorder()

    init(identity: ProfileIdentity, store: AttentionDomainStore, context: ProfileContext) {
        authenticatedIdentity = identity
        self.store = store
        self.context = context
    }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        try await consume(Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#.utf8) + Data([0x0A]))
        try await consume(Data(#"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"sync-item","origin":"other-installation","as":"message","message":{"title":"Synced request","answer_ui":null}}"#.utf8) + Data([0x0A]))
        try await consume(Data(#"{"v":1,"type":"resynced","seq":1}"#.utf8) + Data([0x0A]))
    }

    func acknowledge(_ request: Data) async throws {
        cursorAtAcknowledgement = try store.snapshot(context: context).cursor
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        originalOperationRecorder.append(operationID: operationID, frame: frame)
        return .unresolved
    }
}

private final class OriginalOperationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var operationIDs: [UUID] = []
    private var frames: [Data] = []

    func append(operationID: UUID, frame: Data) {
        lock.lock(); defer { lock.unlock() }
        operationIDs.append(operationID)
        frames.append(frame)
    }

    func snapshot() -> (operationIDs: [UUID], frames: [Data]) {
        lock.lock(); defer { lock.unlock() }
        return (operationIDs, frames)
    }
}

private actor AsyncTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        signaled = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
