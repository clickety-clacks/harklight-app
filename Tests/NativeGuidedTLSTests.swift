import Foundation
import AttentionDomain
import CryptoKit
@testable import HarklightNativeRelay
import Network
import Security
import XCTest
@testable import Harklight

private final class PagingExchangeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var signaled = false

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let resumeImmediately = signaled
            if !resumeImmediately { self.continuation = continuation }
            lock.unlock()
            if resumeImmediately { continuation.resume() }
        }
    }

    func signal() {
        lock.lock()
        signaled = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }
}

private actor PagingControlledReplyChannel {
    private var sentRequests: [String] = []
    private var pendingRequests: [String] = []
    private var requestWaiters: [CheckedContinuation<String, Never>] = []
    private var pendingReplies: [String] = []
    private var replyWaiters: [CheckedContinuation<String, Never>] = []

    func send(_ request: String) {
        sentRequests.append(request)
        if !requestWaiters.isEmpty {
            requestWaiters.removeFirst().resume(returning: request)
        } else {
            pendingRequests.append(request)
        }
    }

    func nextRequest() async -> String {
        await withCheckedContinuation { continuation in
            if !pendingRequests.isEmpty {
                continuation.resume(returning: pendingRequests.removeFirst())
            } else {
                requestWaiters.append(continuation)
            }
        }
    }

    func receive() async -> String {
        await withCheckedContinuation { continuation in
            if !pendingReplies.isEmpty {
                continuation.resume(returning: pendingReplies.removeFirst())
            } else {
                replyWaiters.append(continuation)
            }
        }
    }

    func respond(_ reply: String) {
        if !replyWaiters.isEmpty {
            replyWaiters.removeFirst().resume(returning: reply)
        } else {
            pendingReplies.append(reply)
        }
    }

    func requestsSent() -> [String] { sentRequests }
}

private final class NativeDiagnosticEventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NativeClientDiagnosticEvent] = []

    func append(_ event: NativeClientDiagnosticEvent) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }

    var events: [NativeClientDiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// Actual pinned TLS exercises certificate-free enrollment and the explicit
/// identity proof required for own-device removal. The iOS listener cannot
/// request an optional certificate; that server seam needs server integration.
@MainActor
final class NativeGuidedTLSTests: XCTestCase {
    /// Run only with an isolated, preapproved fixture matching the deployed
    /// server. The fixture remains quiescent after seeding its ordinary message.
    /// Resources are copied into Tests/Fixtures before the unchanged wrapper runs;
    /// this test neither enrolls an identity nor starts or reconfigures a server.
    func testIsolatedForegroundCompletionWithEmptyAndRetainedConversationThreads() async throws {
        struct Fixture: Decodable {
            let relayURL: URL
            let personID: String
            let deviceID: String
            let senderID: String
            let messageID: String
            let ordinaryCursor: UInt64
            let conversationsSupported: Bool
        }
        let bundle = Bundle(for: Self.self)
        guard let configurationURL = bundle.url(forResource: "foreground-post-ack", withExtension: "json") else {
            throw XCTSkip("Requires the isolated foreground-post-ack fixture and preapproved synthetic identity.")
        }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: configurationURL))
        let rootURL = try XCTUnwrap(bundle.url(forResource: "foreground-post-ack-ca", withExtension: "pem"))
        let identityURL = try XCTUnwrap(bundle.url(forResource: "foreground-post-ack-client", withExtension: "p12"))
        let rootDER = try XCTUnwrap(NativeEnrollmentSettings.certificateDER(
            from: String(contentsOf: rootURL, encoding: .utf8)))
        var importedItems: CFArray?
        XCTAssertEqual(SecPKCS12Import(try Data(contentsOf: identityURL) as CFData,
            [kSecImportExportPassphrase as String: "public-fixture-only"] as CFDictionary,
            &importedItems), errSecSuccess)
        let importedIdentity = try XCTUnwrap((importedItems as? [[String: Any]])?.first?[kSecImportItemIdentity as String])
        let clientIdentity = importedIdentity as! SecIdentity
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText(try XCTUnwrap(fixture.relayURL.host)),
            personID: ExactText(fixture.personID), deviceID: ExactText(fixture.deviceID))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let request = RequestKey(accountScope: identity.personID, senderID: ExactText(fixture.senderID),
            messageID: ExactText(fixture.messageID))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
        var store = try AttentionDomainStore(context: context, persistence: persistence)
        let runID = UUID()
        let sessionHandle = ExactText("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")

        for retainedThread in [false, true] {
            let name = retainedThread ? "retained-thread" : "empty-threads"
            if retainedThread {
                // Restore the same identity and committed state. A capable server
                // supplied the thread on the first replay. Only the older server
                // needs synthetic saved history to reproduce its unsupported open.
                store = try AttentionDomainStore(context: context, persistence: persistence)
                let saved = try store.snapshot(context: context)
                let message = try XCTUnwrap(saved.requests[request])
                if !fixture.conversationsSupported {
                    try store.applyConversation(ConversationEvent(sequence: 1,
                        binding: ConversationBinding(request: request, revision: 1),
                        fact: .request(sessionHandle: sessionHandle,
                                       payload: message.originalPayload)), context: context)
                }
                let retained = try XCTUnwrap(store.conversationSnapshot(context: context).threads[request])
                XCTAssertEqual(retained.sessionHandle, sessionHandle)
                let after = try store.snapshot(context: context)
                XCTAssertEqual(after.cursor, saved.cursor)
                XCTAssertEqual(after.requests, saved.requests)
                XCTAssertEqual(after.intents, saved.intents)
                XCTAssertEqual(after.outbox, saved.outbox)
            }
            let expectsConversationReplay = retainedThread || fixture.conversationsSupported
            let before = try store.snapshot(context: context)
            let threadsBefore = try store.conversationSnapshot(context: context)
            XCTAssertTrue(before.outbox.isEmpty)
            XCTAssertTrue(before.intents.isEmpty, "This baseline has no original operation or terminal replay to invent.")
            XCTAssertEqual(threadsBefore.threads.count, retainedThread ? 1 : 0)
            let journal = NativeClientDiagnosticJournal(fileURL: nil)
            let lifecycle = NativeRelayLifecycle()
            let presentation = try LivePresentationStore(store: store, context: context,
                conversationAvailability: lifecycle.conversationAvailability)
            try await lifecycle.activate(store: store, context: context, relayURL: fixture.relayURL,
                clientIdentity: clientIdentity, trustedRootDER: rootDER, diagnostics: journal)
            var checkpoints: [String] = []
            print("Foreground fixture begin run=\(runID) case=\(name) person=\(fixture.personID) device=\(fixture.deviceID)")
            let result = await lifecycle.confirmForegroundProgress(for: context) { progress in
                let cursor = try? store.snapshot(context: context).cursor
                let threads = try? store.conversationSnapshot(context: context).threads.count
                let checkpoint = "transport=\(progress.transportAttemptID?.uuidString ?? "none") " +
                    "stage=\(progress.lastConfirmedStage.map { String(describing: $0) } ?? "none") " +
                    "durable_cursor_at_observation=\(cursor.map(String.init) ?? "unavailable") " +
                    "threads=\(threads.map(String.init) ?? "unavailable")"
                if checkpoints.last != checkpoint { checkpoints.append(checkpoint) }
            }
            let diagnosticsArrived = await eventually {
                journal.events.contains { $0.phase == .foregroundCompletion && $0.attemptID == result.attemptID } &&
                    journal.events.contains {
                        $0.area == .relay && $0.phase == .ordinaryReplay && $0.transition == .completed &&
                            $0.attemptID == result.transportAttemptID
                    } &&
                    (!expectsConversationReplay || journal.events.contains {
                        $0.area == .conversation && $0.phase == .conversationReplay &&
                            $0.transition == (fixture.conversationsSupported ? .completed : .rejected)
                    })
            }
            // A later refresh on this connection must keep ordinary service
            // confirmed without another conversation_open after its refusal.
            let repeatedRefresh = await lifecycle.refreshResultFromTrustedRelay()
            presentation.applyRefreshResult(repeatedRefresh)
            XCTAssertTrue(repeatedRefresh.confirms(context, transportAttemptID: result.transportAttemptID))
            let chatMessage = presentation.conversationUnavailableMessage
            let after = try store.snapshot(context: context)
            let threadsAfter = try store.conversationSnapshot(context: context)
            let diagnostic = NativeForegroundConnectDiagnostic(progress: result,
                operationSnapshot: lifecycle.foregroundOperationDiagnostics(for: context))
            let evidence = [
                "run=\(runID) case=\(name)",
                "person=\(fixture.personID) device=\(fixture.deviceID) profile_generation=\(context.generation)",
                "ordinary_cursor_before=\(before.cursor) ordinary_cursor_after=\(after.cursor)",
                "checkpoint_accepted=\(after.inboxCheckpoint?.checkpointAccepted == true) " +
                    "checkpoint_high_water=\(after.inboxCheckpoint?.highWater.map(String.init) ?? "unavailable")",
                "ordinary_ack_expected=no_empty_replay",
                "conversations_supported_expected=\(fixture.conversationsSupported)",
                "chat_availability_message=\(chatMessage ?? "none")",
                "connection_warning=\(presentation.connectionWarning ?? "none")",
                "conversation_threads_before=\(threadsBefore.threads.count) after=\(threadsAfter.threads.count)",
                "original_operation=none terminal_operation_replay=not_applicable",
                "received_message_readable=\(after.requests[request] != nil)",
                checkpoints.joined(separator: "\n"), diagnostic.shareText, journal.shareText
            ].joined(separator: "\n")
            let attachment = XCTAttachment(string: evidence)
            attachment.name = "Foreground post-ACK \(name)"
            attachment.lifetime = .keepAlways
            add(attachment)
            print(evidence)
            await lifecycle.deactivate()

            XCTAssertTrue(diagnosticsArrived)
            XCTAssertNotNil(result.attemptID)
            let transportID = try XCTUnwrap(result.transportAttemptID)
            XCTAssertFalse(journal.events.contains {
                $0.area == .relay && $0.phase == .acknowledgement && $0.transition == .completed &&
                    ($0.transportAttemptID == transportID || $0.attemptID == transportID)
            }, "An empty replay after checkpoint acceptance has no new ordinary event to ACK.")
            let checkpoint = try XCTUnwrap(after.inboxCheckpoint)
            XCTAssertTrue(checkpoint.checkpointAccepted)
            XCTAssertEqual(checkpoint.highWater, fixture.ordinaryCursor)
            XCTAssertTrue(journal.events.contains {
                $0.area == .relay && $0.phase == .ordinaryReplay && $0.transition == .completed &&
                    $0.attemptID == transportID
            }, "Checkpoint acceptance must be followed by completed ordinary replay on the final transport.")
            // This quiescent fixture advances via inbox_checkpoint_ack, then
            // completes an empty inbox_attach replay. The server trace records
            // those actual replies and the subsequent conversation_open/error.
            XCTAssertEqual(after.cursor, fixture.ordinaryCursor)
            XCTAssertNotNil(after.requests[request], "Received messages remain readable when chat is unavailable.")
            XCTAssertTrue(after.outbox.isEmpty)
            XCTAssertEqual(after.intents, before.intents)
            XCTAssertEqual(threadsAfter.threads.count, expectsConversationReplay ? 1 : 0)
            XCTAssertEqual(result.generationValidation, .passed)
            XCTAssertEqual(result.profileContextValidation, .passed)
            XCTAssertEqual(result.outcome, .confirmed)
            XCTAssertEqual(result.postAckDrainTransition, .completed)
            XCTAssertEqual(result.postAckRelayRefresh, .passed)
            XCTAssertEqual(result.relayContextValidation, .passed)
            XCTAssertNil(presentation.connectionWarning)
            if retainedThread && !fixture.conversationsSupported {
                XCTAssertEqual(chatMessage, "Chat is not available on this server yet.")
                XCTAssertEqual(journal.events.filter {
                    $0.area == .conversation && $0.phase == .conversationReplay && $0.transition == .rejected
                }.count, 1, "Repeated ordinary refresh must not probe refused chat again on this connection.")
                XCTAssertTrue(journal.events.contains {
                    $0.area == .conversation && $0.phase == .conversationReplay &&
                        $0.transition == .rejected && $0.attemptID == transportID
                }, "The deployed server refuses chat, while ordinary foreground confirmation succeeds.")
                XCTAssertFalse(journal.events.contains {
                    $0.area == .conversation && $0.phase == .acknowledgement && $0.transition == .completed
                })
            } else {
                XCTAssertNil(chatMessage)
                if expectsConversationReplay {
                    XCTAssertTrue(journal.events.contains {
                        $0.area == .conversation && $0.phase == .conversationReplay &&
                            $0.transition == .completed && $0.attemptID == transportID
                    })
                    XCTAssertTrue(journal.events.contains {
                        $0.area == .conversation && $0.phase == .acknowledgement &&
                            $0.transition == .completed && $0.attemptID == transportID
                    })
                    XCTAssertFalse(journal.events.contains {
                        $0.area == .conversation && $0.transition == .rejected
                    })
                } else {
                    XCTAssertFalse(journal.events.contains { $0.phase == .conversationReplay })
                }
            }
        }
    }

    func testNativeRelayACKAndPushExchangesKeepFIFORepliesWithTheirRequests() async {
        let pushWaiting = PagingExchangeSignal()
        let gate = RelaySocketExchangeGate(onWaiterQueued: { pushWaiting.signal() })
        let channel = PagingControlledReplyChannel()

        func exchange(_ request: String) async -> String {
            await gate.enter()
            defer { gate.leave() }
            await channel.send(request)
            return await channel.receive()
        }

        let acknowledgement = Task { await exchange("ack:seq:7") }
        let firstRequest = await channel.nextRequest()
        XCTAssertEqual(firstRequest, "ack:seq:7")
        let pushRegistration = Task { await exchange("push_register:revision:3") }
        await pushWaiting.wait()

        let requestsWhileACKOwnsReply = await channel.requestsSent()
        XCTAssertEqual(requestsWhileACKOwnsReply, ["ack:seq:7"],
                       "Push registration must wait while the ACK owns the FIFO reply waiter.")
        await channel.respond("ok:ref:native-ack:seq:7")
        let acknowledgementReply = await acknowledgement.value
        XCTAssertEqual(acknowledgementReply, "ok:ref:native-ack:seq:7")

        let secondRequest = await channel.nextRequest()
        XCTAssertEqual(secondRequest, "push_register:revision:3")
        await channel.respond("ok:ref:native-push:revision:3")
        let pushReply = await pushRegistration.value
        XCTAssertEqual(pushReply, "ok:ref:native-push:revision:3")
        let allRequests = await channel.requestsSent()
        XCTAssertEqual(allRequests, ["ack:seq:7", "push_register:revision:3"])
    }

    func testNativeRelayCursorAccessValidatesItsProfileContext() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        XCTAssertEqual(try store.relayCursor(context: context), 0)

        let otherIdentity = ProfileIdentity(trustedRelayAuthority: context.identity.trustedRelayAuthority,
                                            personID: ExactText("person-B"),
                                            deviceID: ExactText("installation-B"))
        let otherContext = ProfileContext(identity: otherIdentity, transportMode: .relay)
        XCTAssertThrowsError(try store.relayCursor(context: otherContext))

        store.invalidate()
        XCTAssertThrowsError(try store.relayCursor(context: context))
    }

    private let notificationBindingID = "c0e2a155-934c-44fb-bb29-50b22fa7b823"

    private func notificationPayload(sequence: String = "1", message: String = "target",
                                     binding: String? = nil) throws -> JSONValue {
        try JSONValue.parse(Data("""
        {"attention":{"v":1,"type":"sync","locator":{"v":1,"binding_id":"\(binding ?? notificationBindingID)","person_id":"saved-person","device_id":"saved-device-id","sender_id":"sender","message_id":"\(message)","acceptance_seq":\(sequence)}}}
        """.utf8))
    }

    private func notificationRecord() -> NativeEnrollmentRecord {
        var record = approvedRecord(foregroundRelayConfirmed: true, notificationExplanationSeen: true)
        record.notificationProfileGeneration = UUID()
        record.pushBinding = NativePushBinding(address: String(repeating: "a", count: 64),
            operationID: UUID(), revision: 7, accepted: true)
        record.notificationBindings = [NativeNotificationBinding(bindingID: ExactText(notificationBindingID),
            operationID: record.pushBinding!.operationID, revision: 7)]
        return record
    }

    func testPushBindingReplyCorrelationAndDurableSameOperationRecovery() throws {
        let service = "Harklight.push-binding-test." + UUID().uuidString
        defer { deleteEnrollmentRecord(service: service) }
        var record = approvedRecord(foregroundRelayConfirmed: true, notificationExplanationSeen: true)
        record.pushBinding = NativePushBinding(address: String(repeating: "a", count: 64),
            operationID: UUID(), revision: 7, accepted: false)
        try saveEnrollmentRecord(record, service: service)
        let store = NativeEnrollmentStore(service: service)
        let original = try XCTUnwrap(record.pushBinding)
        XCTAssertEqual(try store.pendingPushRegistration(address: original.address, for: record.deviceID), original)
        XCTAssertEqual(try store.pendingPushRegistration(address: original.address, for: record.deviceID), original,
                       "A lost reply keeps the original registration operation and revision")
        let good = try JSONValue.parse(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-push\",\"revision\":7,\"binding_id\":\"\(notificationBindingID)\",\"profile_id\":\"harklight-sandbox\"}".utf8))
        XCTAssertThrowsError(try PushBindingReply.registration(good, revision: 8))
        XCTAssertNil(try store.load()?.notificationBindings)
        let id = try PushBindingReply.registration(good, revision: 7)
        XCTAssertThrowsError(try PushBindingReply.registration(good, revision: 7, profile: .production),
                             "A registration reply for another profile cannot be accepted.")
        try store.markPushAccepted(original, bindingID: id, expected: record)
        let saved = try XCTUnwrap(store.load())
        XCTAssertTrue(saved.pushBinding?.accepted == true)
        XCTAssertEqual(saved.pushBinding?.operationID, original.operationID)
        XCTAssertEqual(saved.notificationBindings?.first?.bindingID, ExactText(id))
        XCTAssertEqual(saved.notificationBindings?.first?.revision, original.revision)
        XCTAssertNotNil(saved.notificationProfileGeneration)
        XCTAssertEqual(saved.trustedRootDER, record.trustedRootDER)
        XCTAssertEqual(saved.personID, record.personID)
        XCTAssertThrowsError(try store.markPushAccepted(original, bindingID: id, expected: record),
                             "A stale profile/operation snapshot cannot commit a later reply")
        let rotated = try XCTUnwrap(store.pendingPushRegistration(address: String(repeating: "b", count: 64), for: record.deviceID))
        XCTAssertEqual(rotated.revision, 8)
        XCTAssertEqual(try store.load()?.notificationBindings, saved.notificationBindings,
                       "Delayed notifications can retain the old authenticated association")

        let sandboxStatus = try JSONValue.parse(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-push-status\",\"push\":{\"revision\":7,\"binding_id\":\"\(id)\",\"profile_id\":\"harklight-sandbox\"}}".utf8))
        XCTAssertEqual(try PushBindingReply.status(sandboxStatus, revision: 7,
                                                   profile: .sandbox), id)
        XCTAssertThrowsError(try PushBindingReply.status(sandboxStatus, revision: 8,
                                                          profile: .sandbox))
        XCTAssertThrowsError(try PushBindingReply.status(sandboxStatus, revision: 7,
                                                          profile: .production))
        XCTAssertThrowsError(try PushBindingReply.registration(sandboxStatus, revision: 7))

        let productionStatus = try JSONValue.parse(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-push-status\",\"push\":{\"revision\":7,\"binding_id\":\"\(id)\",\"profile_id\":\"harklight-production\"}}".utf8))
        XCTAssertEqual(try PushBindingReply.status(productionStatus, revision: 7,
                                                   profile: .production), id)
        XCTAssertThrowsError(try PushBindingReply.status(productionStatus, revision: 7,
                                                          profile: .sandbox))
    }

    func testPushRegistrationProfileSelectionFollowsBuildConfiguration() {
        XCTAssertEqual(PushRegistrationProfile.forBuildConfiguration(.debug), .sandbox)
        XCTAssertEqual(PushRegistrationProfile.forBuildConfiguration(.release), .production)
        #if DEBUG
        XCTAssertEqual(PushRegistrationProfile.current, .sandbox)
        #else
        XCTAssertEqual(PushRegistrationProfile.current, .production)
        #endif
    }

    func testBuild6AcceptedProductionBindingSurvivesUpgradeAndAdvancesOnlyWhenBlocked() throws {
        let service = "Harklight.build6-upgrade." + UUID().uuidString
        defer { deleteEnrollmentRecord(service: service) }

        // Build 6 persisted this synthesized Codable shape under the unchanged
        // Keychain service/account. Newer optional fields are absent.
        let address = String(repeating: "a", count: 64)
        let operationID = "11111111-1111-4111-8111-111111111111"
        let bindingID = "22222222-2222-4222-8222-222222222222"
        let profileGeneration = "33333333-3333-4333-8333-333333333333"
        let build6Record = Data("""
        {"host":"relay.example.test","enrollmentPort":18444,"relayPort":18443,"trustedRootDER":"AQID","identityLabel":"saved-device","deviceID":"saved-device-id","approvalCode":"ABCDEFGH","statusSecret":"\(String(repeating: "b", count: 64))","expiresAt":1,"statusExpiresAt":2,"personID":"saved-person","pushBinding":{"address":"\(address)","operationID":"\(operationID)","revision":2,"accepted":true},"notificationProfileGeneration":"\(profileGeneration)","notificationBindings":[{"bindingID":{"rawValue":"\(bindingID)"},"operationID":"\(operationID)","revision":2}]}
        """.utf8)
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                   kSecAttrService as String: service,
                   kSecAttrAccount as String: "current-installation",
                   kSecValueData as String: build6Record,
                   kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        XCTAssertEqual(SecItemAdd(add as CFDictionary, nil), errSecSuccess)

        let store = NativeEnrollmentStore(service: service)
        let upgraded = try XCTUnwrap(store.load())
        let savedBinding = try XCTUnwrap(upgraded.pushBinding)
        XCTAssertTrue(savedBinding.accepted)
        XCTAssertEqual(savedBinding.address, address)
        XCTAssertEqual(savedBinding.revision, 2)
        XCTAssertEqual(upgraded.notificationBindings?.first?.bindingID.rawValue, bindingID)

        let blocked = try JSONValue.parse(Data("""
        {"v":1,"type":"ok","ref":"native-push-status","push":{"revision":2,"state":"blocked_configuration","attempt_count":1,"binding_id":"\(bindingID)","profile_id":"harklight-production"}}
        """.utf8))
        let status = try XCTUnwrap(PushBindingReply.activeStatus(blocked))
        let wrongRevision = try JSONValue.parse(Data("""
        {"v":1,"type":"ok","ref":"native-push-status","push":{"revision":3,"state":"blocked_configuration","attempt_count":1,"binding_id":"\(bindingID)","profile_id":"harklight-production"}}
        """.utf8))
        XCTAssertNil(try store.pendingBlockedConfigurationRegistration(
            address: address, for: upgraded.deviceID,
            status: try XCTUnwrap(PushBindingReply.activeStatus(wrongRevision)), profile: .production))
        let wrongBinding = try JSONValue.parse(Data("""
        {"v":1,"type":"ok","ref":"native-push-status","push":{"revision":2,"state":"blocked_configuration","attempt_count":1,"binding_id":"44444444-4444-4444-8444-444444444444","profile_id":"harklight-production"}}
        """.utf8))
        XCTAssertNil(try store.pendingBlockedConfigurationRegistration(
            address: address, for: upgraded.deviceID,
            status: try XCTUnwrap(PushBindingReply.activeStatus(wrongBinding)), profile: .production))
        let wrongProfile = try JSONValue.parse(Data("""
        {"v":1,"type":"ok","ref":"native-push-status","push":{"revision":2,"state":"blocked_configuration","attempt_count":1,"binding_id":"\(bindingID)","profile_id":"harklight-sandbox"}}
        """.utf8))
        XCTAssertNil(try store.pendingBlockedConfigurationRegistration(
            address: address, for: upgraded.deviceID,
            status: try XCTUnwrap(PushBindingReply.activeStatus(wrongProfile)), profile: .production))
        XCTAssertEqual(try store.load()?.pushBinding, savedBinding,
                       "A remote profile or binding mismatch must not change local registration state.")

        let replacement = try XCTUnwrap(store.pendingBlockedConfigurationRegistration(
            address: address, for: upgraded.deviceID, status: status, profile: .production))
        XCTAssertEqual(replacement.address, savedBinding.address)
        XCTAssertEqual(replacement.revision, 3)
        XCTAssertNotEqual(replacement.operationID, savedBinding.operationID)
        XCTAssertEqual(String(replacement.operationID.uuidString.split(separator: "-")[2].prefix(1)), "4",
                       "Each new logical registration uses a UUIDv4 operation ID.")
        XCTAssertFalse(replacement.accepted)

        XCTAssertEqual(try store.load()?.pushBinding, replacement)
        XCTAssertEqual(try store.pendingPushRegistration(address: address, for: upgraded.deviceID), replacement,
                       "An ambiguous retry reuses the saved operation and revision.")
        XCTAssertNil(try store.pendingBlockedConfigurationRegistration(
            address: address, for: upgraded.deviceID, status: status, profile: .production),
            "The same blocked status cannot mint a second revision while one is pending.")

        let ready = try JSONValue.parse(Data("""
        {"v":1,"type":"ok","ref":"native-push-status","push":{"revision":2,"state":"ready","attempt_count":1,"binding_id":"\(bindingID)","profile_id":"harklight-production"}}
        """.utf8))
        XCTAssertNil(try store.pendingBlockedConfigurationRegistration(
            address: address, for: upgraded.deviceID,
            status: try XCTUnwrap(PushBindingReply.activeStatus(ready)), profile: .production))
    }

    @MainActor
    func testForegroundActivationRequestsBlockedPushStatusOnce() async throws {
        let namespace = "Harklight.activation-push-status." + UUID().uuidString
        defer { deleteEnrollmentRecord(service: namespace) }
        let record = notificationRecord()
        let context = ProfileContext(identity: try XCTUnwrap(NativeNotificationProfile(record)).identity,
                                     transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let presentation = try LivePresentationStore(store: domain, context: context)
        var checks: [Bool] = []
        let app = NativeAppLaunch(arguments: [], enrollmentStore: NativeEnrollmentStore(service: namespace),
            joinStore: NativeGuidedJoinStore(namespace: namespace + ".join"),
            initialState: .live(presentation), initialEnrollmentRecord: record,
            refreshOperation: { checkBlockedPush in
                checks.append(checkBlockedPush)
                return .unavailable
            })

        await app.refreshForForegroundActivation()
        await app.refreshLive()
        await app.refreshLive()

        XCTAssertEqual(checks, [true, false, false],
                       "Periodic foreground refreshes must not repeat the activation-only status check.")
    }

    func testLegacyAcceptedPushBindingStatusRecoveryAddsOnlyAuthenticatedAssociation() throws {
        let service = "Harklight.push-legacy-test." + UUID().uuidString
        defer { deleteEnrollmentRecord(service: service) }
        var record = approvedRecord(foregroundRelayConfirmed: true, notificationExplanationSeen: true)
        record.pushBinding = NativePushBinding(address: String(repeating: "a", count: 64),
            operationID: UUID(), revision: 4, accepted: true)
        try saveEnrollmentRecord(record, service: service)
        let store = NativeEnrollmentStore(service: service)
        XCTAssertNil(try store.pendingPushRegistration(address: record.pushBinding!.address, for: record.deviceID))
        let reply = try JSONValue.parse(Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-push-status\",\"push\":{\"revision\":4,\"binding_id\":\"\(notificationBindingID)\",\"profile_id\":\"harklight-sandbox\"}}".utf8))
        let id = try XCTUnwrap(PushBindingReply.status(reply, revision: 4))
        try store.markPushAccepted(record.pushBinding!, bindingID: id, expected: record)
        let recovered = try XCTUnwrap(store.load())
        XCTAssertEqual(recovered.pushBinding, record.pushBinding)
        XCTAssertEqual(recovered.identityLabel, record.identityLabel)
        XCTAssertEqual(recovered.trustedRootDER, record.trustedRootDER)
        XCTAssertEqual(recovered.notificationBindings?.first?.bindingID, ExactText(id))
    }

    func testNotificationBindingSelectionIsExactAndNeverChoosesByMessageText() throws {
        let record = notificationRecord()
        let locator = try XCTUnwrap(NativeNotificationLocator(notificationPayload()))
        var other = record
        other.host = "another.example"
        other.notificationProfileGeneration = UUID()
        other.notificationBindings = [NativeNotificationBinding(bindingID: ExactText(UUID().uuidString), operationID: UUID(), revision: 1)]
        XCTAssertEqual(locator.profile(in: [other, record]), NativeNotificationProfile(record))
        XCTAssertNil(locator.profile(in: [other]))
        other.notificationBindings = record.notificationBindings
        XCTAssertNil(locator.profile(in: [other, record]), "An ambiguous binding cannot choose an account")
        other = record
        other.personID = "another-person"
        XCTAssertNil(locator.profile(in: [other]))
        let wrongDevice = try JSONValue.parse(Data(notificationPayload().canonicalJSON
            .replacingOccurrences(of: "saved-device-id", with: "replacement-device").utf8))
        XCTAssertNil(NativeNotificationLocator(wrongDevice)?.profile(in: [record]))
        XCTAssertNil(locator.profile(in: []), "Removed profiles and archives are not candidates")
        XCTAssertNil(NativeNotificationLocator(try notificationPayload(sequence: "1.5")))
        XCTAssertNil(NativeNotificationLocator(try notificationPayload(sequence: "true")))
        XCTAssertNil(NativeNotificationLocator(try notificationPayload(sequence: "0")))
        let unsupported = try JSONValue.parse(Data(notificationPayload().canonicalJSON
            .replacingOccurrences(of: "\"v\":1", with: "\"v\":2").utf8))
        XCTAssertNil(NativeNotificationLocator(unsupported))
        XCTAssertEqual(NativeNotificationLocator(try notificationPayload(sequence: "9007199254740993"))?.acceptanceSequence,
                       9_007_199_254_740_993)
    }

    func testNotificationOpenUsesCurrentTerminalStateAndNeverChangesPendingOperations() async throws {
        let namespace = "Harklight.notification-open." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace); deleteEnrollmentRecord(service: namespace) }
        let record = notificationRecord()
        try saveEnrollmentRecord(record, service: namespace)
        let context = ProfileContext(identity: try XCTUnwrap(NativeNotificationProfile(record)).identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("target"))
        let pendingKey = RequestKey(accountScope: context.identity.personID, senderID: ExactText("sender"), messageID: ExactText("pending"))
        let payload = try JSONValue.parse(Data(#"{"title":"Same title"}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        try domain.apply(RelayEvent(sequence: 2, body: .delivery(StoredRequest(key: pendingKey, originalPayload: payload), .message)), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        live.selectAction(ExactText("reply"), input: nil, for: pendingKey)
        live.updateCompatibilityText("An existing deliberate answer", action: ExactText("reply"), for: pendingKey)
        let receipt = try live.submit(pendingKey)
        let before = try domain.snapshot(context: context)
        let router = NativeNotificationRouter(defaults: defaults)
        router.receive(try notificationPayload(), opened: true)
        var refreshes = 0
        let app = NativeAppLaunch(arguments: [], enrollmentStore: NativeEnrollmentStore(service: namespace),
            joinStore: NativeGuidedJoinStore(namespace: namespace + ".join"),
            initialState: .live(live), initialEnrollmentRecord: record, notificationRouter: router,
            refreshOperation: { _ in
                refreshes += 1
                try! domain.apply(RelayEvent(sequence: 3, body: .terminal(key, .answered, nil)), context: context)
                try! live.refreshFromDurableStore()
                return NativeRelayRefreshResult(relayConfirmed: true, pushRegistration: .notAttempted,
                    confirmedContext: context, confirmedTransportAttemptID: UUID())
            })
        await app.handleNotification()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(app.notificationNavigation?.request, key)
        XCTAssertEqual(live.request(for: key)?.lifecycleStatus, .answered)
        XCTAssertNil(router.intent)
        let after = try domain.snapshot(context: context)
        XCTAssertEqual(after.outbox, before.outbox)
        XCTAssertEqual(after.intents, before.intents)
        XCTAssertEqual(after.drafts, before.drafts)
        XCTAssertEqual(after.intents[receipt.intentID], before.intents[receipt.intentID])
        let persisted = try XCTUnwrap(persistence.load(identity: context.identity))
        router.receive(try notificationPayload(), opened: false)
        XCTAssertNil(router.intent)
        XCTAssertEqual(try persistence.load(identity: context.identity), persisted)
    }

    func testColdPendingNotificationWaitsForOrdinaryLoadingAndRejectsSequenceOrGenerationChange() throws {
        let namespace = "Harklight.notification-cold." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let record = notificationRecord()
        let context = ProfileContext(identity: try XCTUnwrap(NativeNotificationProfile(record)).identity, transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let payload = try JSONValue.parse(Data(#"{"title":"Same title"}"#.utf8))
        let key = try XCTUnwrap(NativeNotificationLocator(notificationPayload())).request
        let first = NativeNotificationRouter(defaults: defaults)
        first.receive(try notificationPayload(), opened: true)
        let cold = NativeNotificationRouter(defaults: defaults)
        XCTAssertNotNil(cold.intent)
        XCTAssertNil(cold.resolve(records: [record], context: context, requests: [], synchronized: true))
        XCTAssertNotNil(cold.intent?.locator, "An unloaded target remains pending without a page request")
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key, originalPayload: payload), .message)), context: context)
        let port = AttentionDomainPort(store: domain)
        let requests = try port.observe(context: port.context).requests
        XCTAssertNil(cold.resolve(records: [record], context: context, requests: requests, synchronized: false))
        XCTAssertEqual(cold.resolve(records: [record], context: context, requests: requests, synchronized: true), key)
        cold.receive(try notificationPayload(sequence: "2"), opened: true)
        XCTAssertNil(cold.resolve(records: [record], context: context, requests: requests, synchronized: true))
        let replaced = ProfileContext(identity: context.identity, transportMode: .relay)
        XCTAssertNil(cold.resolve(records: [record], context: replaced, requests: requests, synchronized: true))
        XCTAssertNil(cold.intent?.locator, "A changed live generation invalidates in-flight navigation")
        first.receive(try notificationPayload(), opened: true)
        _ = first.resolve(records: [record], context: context, requests: [], synchronized: false)
        let afterRestart = NativeNotificationRouter(defaults: defaults)
        var replacedRecord = record
        replacedRecord.notificationProfileGeneration = UUID()
        XCTAssertNil(afterRestart.resolve(records: [replacedRecord], context: context, requests: requests, synchronized: true))
        XCTAssertNil(afterRestart.intent?.locator, "A replacement saved generation cannot inherit cold intent")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        XCTAssertTrue(try domain.snapshot(context: context).intents.isEmpty)
    }

    func testNotificationRecoveryKeepsRetainedRowsWithoutMarkingThemSeen() async throws {
        let namespace = "Harklight.notification-recovery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace); deleteEnrollmentRecord(service: namespace) }
        let record = notificationRecord()
        try saveEnrollmentRecord(record, service: namespace)
        let context = ProfileContext(identity: try XCTUnwrap(NativeNotificationProfile(record)).identity,
                                     transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = try XCTUnwrap(NativeNotificationLocator(notificationPayload())).request
        let informationalPayload = try JSONValue.parse(Data(#"{"title":"Build complete","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: informationalPayload), .message)),
            context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(live.request(for: key)?.informationalSeenStatus, .available)

        let router = NativeNotificationRouter(defaults: defaults)
        var refreshes = 0
        let app = NativeAppLaunch(arguments: [], enrollmentStore: NativeEnrollmentStore(service: namespace),
            joinStore: NativeGuidedJoinStore(namespace: namespace + ".join"),
            initialState: .live(live), initialEnrollmentRecord: record, notificationRouter: router,
            refreshOperation: { _ in
                refreshes += 1
                guard refreshes > 1 else { return .unavailable }
                return NativeRelayRefreshResult(relayConfirmed: true, pushRegistration: .notAttempted,
                    confirmedContext: context, confirmedTransportAttemptID: UUID())
            })
        let before = try persistence.load(identity: context.identity)
        live.selectRequest(key)
        XCTAssertEqual(live.selectedRequestKey, key)
        XCTAssertEqual(try persistence.load(identity: context.identity), before,
                       "Opening a request does not record its Seen action.")
        router.receive(try notificationPayload(), opened: true)
        await app.handleNotification()

        XCTAssertEqual(refreshes, 1)
        XCTAssertNil(app.notificationNavigation?.request)
        XCTAssertEqual(app.notificationNavigationMessage,
                       "Could not verify notification. Checking again while open.")
        let retained = try XCTUnwrap(live.inboxRows.first { $0.key == key })
        XCTAssertFalse(retained.belongsToReplied)
        XCTAssertTrue(retained.canMarkSeen)
        XCTAssertEqual(live.request(for: key)?.informationalSeenStatus, .available)
        XCTAssertEqual(try persistence.load(identity: context.identity), before)

        await app.refreshLive()
        XCTAssertEqual(refreshes, 2)
        XCTAssertEqual(app.notificationNavigation?.request, key)
        XCTAssertEqual(live.selectedRequestKey, key)
        XCTAssertNil(app.notificationNavigationMessage)
        XCTAssertEqual(live.request(for: key)?.informationalSeenStatus, .available,
                       "Routing a notification must not record Seen, even after a confirmed refresh.")
        let after = try domain.snapshot(context: context)
        XCTAssertTrue(after.outbox.isEmpty)
        XCTAssertTrue(after.intents.isEmpty)
        XCTAssertEqual(try persistence.load(identity: context.identity), before)
    }

    func testLegacyAndUnknownNotificationOpenInboxWithoutSelectingSimilarRows() async throws {
        let namespace = "Harklight.notification-fallback." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace); deleteEnrollmentRecord(service: namespace) }
        let record = notificationRecord()
        try saveEnrollmentRecord(record, service: namespace)
        let context = ProfileContext(identity: try XCTUnwrap(NativeNotificationProfile(record)).identity, transportMode: .relay)
        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let key = try XCTUnwrap(NativeNotificationLocator(notificationPayload())).request
        try domain.apply(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: key,
            originalPayload: try JSONValue.parse(Data(#"{"title":"Duplicated title"}"#.utf8))), .message)), context: context)
        let live = try LivePresentationStore(store: domain, context: context)
        let router = NativeNotificationRouter(defaults: defaults)
        let app = NativeAppLaunch(arguments: [], enrollmentStore: NativeEnrollmentStore(service: namespace),
            joinStore: NativeGuidedJoinStore(namespace: namespace + ".join"),
            initialState: .live(live), initialEnrollmentRecord: record, notificationRouter: router,
            refreshOperation: { _ in .unavailable })
        let before = try persistence.load(identity: context.identity)
        router.receive(try notificationPayload(), opened: true)
        await app.handleNotification()
        XCTAssertNil(app.notificationNavigation?.request)
        XCTAssertNotNil(router.intent?.locator)
        XCTAssertNotNil(app.notificationNavigationMessage)
        XCTAssertEqual(try persistence.load(identity: context.identity), before)
        for payload in [try JSONValue.parse(Data(#"{"attention":{"v":1,"type":"sync"}}"#.utf8)),
                        try notificationPayload(binding: UUID().uuidString), .null] {
            router.receive(payload, opened: true)
            await app.handleNotification()
            XCTAssertNil(app.notificationNavigation?.request)
            XCTAssertNil(live.selectedRequestKey)
            XCTAssertNil(router.intent)
            XCTAssertEqual(try persistence.load(identity: context.identity), before)
        }
    }

    func testOrdinaryInboxGroupsUnresolvedThenResolvedAndUsesDescendingAcceptanceOrder() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-order"), deviceID: ExactText("device-order"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
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

    func testExplicitSeenRequiresCanonicalDescriptorAndConfirmsOnlyAuthorizedEvidence() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-seen"), deviceID: ExactText("device-seen"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let seenKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("notice"))
        let remotelySeenKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("remote-seen"))
        let competingSeenKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("competing-seen"))
        let originSeenKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("origin-seen"))
        let legacyKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("legacy"))
        let misleadingLabelKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("misleading-label"))
        let seenPayload = try JSONValue.parse(Data(#"{"title":"Release complete","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}"#.utf8))
        let seenValue = try JSONValue.parse(Data(#"{"acknowledgment":"seen"}"#.utf8))
        let legacyPayload = try JSONValue.parse(Data(#"{"title":"Legacy request"}"#.utf8))
        let misleadingLabelPayload = try JSONValue.parse(Data(#"{"title":"Still a request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":"different"}]}}"#.utf8))
        _ = store.applyRelayEvent(RelayEvent(sequence: 1, body: .delivery(StoredRequest(key: seenKey, originalPayload: seenPayload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 2, body: .delivery(StoredRequest(key: legacyKey, originalPayload: legacyPayload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 3, body: .delivery(StoredRequest(key: misleadingLabelKey, originalPayload: misleadingLabelPayload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 4, body: .delivery(StoredRequest(key: remotelySeenKey, originalPayload: seenPayload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 5, body: .delivery(StoredRequest(key: competingSeenKey, originalPayload: seenPayload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 6, body: .delivery(StoredRequest(key: originSeenKey, originalPayload: seenPayload), .message)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 7, body: .terminal(remotelySeenKey, .answered, nil)), context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 8, body: .terminal(originSeenKey, .answered, seenValue)), context: context)

        let port = AttentionDomainPort(store: store)
        let initial = try XCTUnwrap(port.inspect(context: port.context, request: seenKey).requests.first)
        XCTAssertEqual(initial.informationalSeenStatus, .available)
        XCTAssertNil(try port.observe(context: port.context).requests.first(where: { $0.key == legacyKey })?.informationalSeenStatus)
        let legacy = try XCTUnwrap(port.inspect(context: port.context, request: legacyKey).requests.first)
        guard case let .compatibility(legacyActions) = legacy.projection else {
            return XCTFail("A missing answer_ui must retain the compatibility Reply control.")
        }
        XCTAssertEqual(legacyActions.first?.label, ExactText("Reply"))
        XCTAssertNil(try port.observe(context: port.context).requests.first(where: { $0.key == misleadingLabelKey })?.informationalSeenStatus)
        XCTAssertEqual(try XCTUnwrap(port.inspect(context: port.context, request: remotelySeenKey).requests.first).informationalSeenStatus,
                       .resolvedWithoutSeen,
                       "An answer-free terminal from another device is not a local operation receipt.")
        XCTAssertEqual(try XCTUnwrap(port.inspect(context: port.context, request: originSeenKey).requests.first).informationalSeenStatus,
                       .confirmed, "An authorized origin answer remains sufficient confirmation.")

        let live = try LivePresentationStore(store: store, context: context)
        let receipt = try live.submit(seenKey, explicitCompatibilityAction: ExactText("seen"))
        XCTAssertTrue(receipt.exactAnswer.semanticallyEquals(seenValue))
        XCTAssertEqual(live.request(for: seenKey)?.informationalSeenStatus, .pending)

        try store.recordAcceptedOperation(receipt.intentID, operationID: receipt.opID,
                                          terminalSequence: 9, context: context)
        _ = store.applyRelayEvent(RelayEvent(sequence: 9, body: .terminal(seenKey, .answered, nil)), context: context)
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: seenKey)?.informationalSeenStatus, .confirmed)

        _ = try live.submit(competingSeenKey, explicitCompatibilityAction: ExactText("seen"))
        _ = store.applyRelayEvent(RelayEvent(sequence: 10, body: .terminal(competingSeenKey, .answered, nil)), context: context)
        try live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: competingSeenKey)?.informationalSeenStatus, .resolvedWithoutSeen,
                       "A competing terminal cannot confirm an unaccepted local Seen operation.")
    }

    func testSyntheticOrdinaryReplayMapsSeenAndReplyThenConfirmsOnlyAfterMatchingReceiptAndAck() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-wire-order"), deviceID: ExactText("device-wire-order"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let store = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let seenKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("notice"))
        let structuredKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("structured"))
        let legacyKey = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"), messageID: ExactText("legacy"))
        let session = OrdinaryOrderingRelaySession(identity: identity)
        let core = try NativeRelayCore(store: store, context: context, session: session)

        let firstHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(firstHigh, 3)
        XCTAssertEqual(session.acknowledgedSequences(), [3], "The view must follow the durable contiguous cursor ACK.")

        let live = try LivePresentationStore(store: store, context: context)
        let rows = live.inboxRows
        XCTAssertEqual(rows.map(\.key), [legacyKey, structuredKey, seenKey],
                       "The newest unresolved acceptance appears first, independent of sender content type.")
        XCTAssertEqual(rows.map(\.isResolved), [false, false, false])
        XCTAssertEqual(rows.last?.symbol, "info.circle")

        let port = AttentionDomainPort(store: store)
        let seen = try XCTUnwrap(port.inspect(context: port.context, request: seenKey).requests.first)
        XCTAssertEqual(seen.informationalSeenStatus, .available)
        guard case let .compatibility(seenActions) = seen.projection else {
            return XCTFail("The exact informational descriptor must map to one Seen value action.")
        }
        XCTAssertEqual(seenActions, [ProjectedAction(id: ExactText("seen"), label: ExactText("Seen"), kind: .value)])

        let structured = try XCTUnwrap(port.inspect(context: port.context, request: structuredKey).requests.first)
        guard case let .compatibility(structuredActions) = structured.projection else {
            return XCTFail("A recognized structured answer descriptor must retain its Reply action.")
        }
        XCTAssertEqual(structuredActions.map(\.id), [ExactText("approve")])
        XCTAssertEqual(structuredActions.map(\.label), [ExactText("Approve")])
        XCTAssertEqual(structuredActions.map(\.kind), [.value])

        let legacy = try XCTUnwrap(port.inspect(context: port.context, request: legacyKey).requests.first)
        guard case let .compatibility(legacyActions) = legacy.projection else {
            return XCTFail("A missing answer_ui must remain the compatibility Reply path.")
        }
        XCTAssertEqual(legacyActions.map(\.label), [ExactText("Reply")])

        let receipt = try live.submit(seenKey, explicitCompatibilityAction: ExactText("seen"))
        let seenAnswer = try JSONValue.parse(Data(#"{"acknowledgment":"seen"}"#.utf8))
        XCTAssertEqual(receipt.exactAnswer, seenAnswer)
        XCTAssertEqual(live.request(for: seenKey)?.informationalSeenStatus, .pending)

        let secondHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(secondHigh, 4)
        XCTAssertEqual(session.acknowledgedSequences(), [3, 4],
                       "The checkpoint at 3 is ACKed separately; only the post-H terminal uses ordinary ACK.")
        let sent = try XCTUnwrap(session.sentOriginalOperation())
        XCTAssertEqual(sent.operationID, receipt.opID)
        let answerFrame = try JSONValue.parse(sent.frame)
        XCTAssertEqual(answerFrame.uniqueValue(named: "op_id")?.stringValue, ExactText(receipt.opID.uuidString.lowercased()))
        XCTAssertEqual(answerFrame.uniqueValue(named: "sender_id")?.stringValue, seenKey.senderID)
        XCTAssertEqual(answerFrame.uniqueValue(named: "message_id")?.stringValue, seenKey.messageID)
        XCTAssertEqual(answerFrame.uniqueValue(named: "answer"), receipt.exactAnswer)

        try live.refreshFromDurableStore()
        XCTAssertEqual(live.request(for: seenKey)?.informationalSeenStatus, .confirmed)
        XCTAssertEqual(live.request(for: seenKey)?.isResolved, true)
        XCTAssertEqual(live.openRequests.map(\.key), [legacyKey, structuredKey])
        XCTAssertEqual(live.resolvedRequests.map(\.key), [seenKey])
        XCTAssertTrue(live.inboxRows.last?.status.contains("Seen confirmed") == true)
        XCTAssertTrue(live.inboxRows.last?.isResolved == true,
                      "Resolved content stays in the ordered inbox projection below open requests.")
    }

    func testOnlyUnknownConversationOpenIsUnavailableAndOrdinaryExchangesContinue() async throws {
        let namespace = "Harklight.chat-capability-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let bindingID = UUID().uuidString.lowercased()
        for (reason, ref, acceptedFirst, missingChat) in [
            ("unknown_type", "native-conversation-sync", false, true),
            ("unknown_type", "unrelated-request", false, false),
            ("invalid_cursor", "native-conversation-sync", false, false),
            ("unknown_type", "native-conversation-sync", true, false)
        ] {
            let relay = try LocalRelayWebSocket(expectedDevice: identity.deviceID) { text in
                if text.contains("\"conversation_open\"") {
                    let error = "{\"v\":1,\"type\":\"error\",\"ref\":\"\(ref)\",\"reason\":\"\(reason)\"}\n"
                    return acceptedFirst ? ["{\"v\":1,\"type\":\"ok\",\"ref\":\"native-conversation-sync\"}\n", error] : [error]
                }
                if text.contains("\"inbox_page\"") {
                    return ["{\"v\":1,\"type\":\"ok\",\"ref\":\"page\"}\n"]
                }
                if text.contains("\"push_register\"") {
                    let frame = try? JSONValue.parse(Data(text.utf8))
                    XCTAssertEqual(frame?.uniqueValue(named: "profile_id")?.stringValue?.rawValue,
                                   PushRegistrationProfile.current.rawValue)
                    return ["{\"v\":1,\"type\":\"ok\",\"ref\":\"native-push\",\"revision\":1,\"binding_id\":\"\(bindingID)\",\"profile_id\":\"\(PushRegistrationProfile.current.rawValue)\"}\n"]
                }
                if text.contains("\"answer\"") {
                    return ["{\"v\":1,\"type\":\"ok\",\"seq\":2}\n"]
                }
                return []
            }
            defer { relay.close() }
            let port = try await relay.start()
            let context = ProfileContext(identity: ProfileIdentity(
                trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
                deviceID: ExactText(identity.deviceID)), transportMode: .relay)
            let session = try URLSessionInstallationSession(
                profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
                clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: relay.rootDER)
            do {
                try await session.openConversation(ConversationWire(profile: context).open(since: 0)) { _ in }
                XCTFail("This server refuses the conversation request.")
            } catch InstallationTransportError.conversationsUnavailable {
                XCTAssertTrue(missingChat)
            } catch InstallationTransportError.serverRejected {
                XCTAssertFalse(missingChat)
            }
            if missingChat {
                let page = try await session.inboxRequest(
                    Data(#"{"v":1,"type":"inbox_page","ref":"page"}"#.utf8) + Data([0x0A]), ref: "page")
                XCTAssertEqual(try JSONValue.parse(page).uniqueValue(named: "ref")?.stringValue?.rawValue, "page")
                let push = try await session.registerPush(address: String(repeating: "a", count: 64),
                                                         operationID: UUID(), revision: 1)
                XCTAssertEqual(push, bindingID)
                let operation = UUID()
                let answer = try await session.sendOriginalOperation(
                    Data(#"{"v":1,"type":"answer"}"#.utf8) + Data([0x0A]), operationID: operation)
                XCTAssertEqual(answer, .accepted(operationID: operation, terminalSequence: 2))
            }
            await session.close()
        }
    }

    func testOlderRelayUnsupportedVersionResponseMarksNoCommentUnsupported() async throws {
        let namespace = "Harklight.no-comment-compatibility-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let relay = try LocalRelayWebSocket(expectedDevice: identity.deviceID) { text in
            guard text.contains("\"type\":\"answer_no_comment\"") else { return [] }
            return ["{\"v\":1,\"type\":\"error\",\"reason\":\"unsupported_version\"}\n"]
        }
        defer { relay.close() }
        let port = try await relay.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
            deviceID: ExactText(identity.deviceID)), transportMode: .relay)
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: relay.rootDER)
        let operationID = UUID()
        let result = try await session.sendOriginalOperation(
            Data(#"{"type":"answer_no_comment","request_id":"request","request_revision":1}"#.utf8) + Data([0x0A]),
            operationID: operationID)
        XCTAssertEqual(result, .unsupported(operationID: operationID),
                       "An older relay's version-first rejection leaves No comment unavailable, never a text fallback.")
        await session.close()
    }

    func testGenericNoCommentServerErrorIsDefinitiveNotDelivered() async throws {
        let namespace = "Harklight.no-comment-rejection-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let relay = try LocalRelayWebSocket(expectedDevice: identity.deviceID) { text in
            guard text.contains("\"type\":\"answer_no_comment\"") else { return [] }
            if text.contains("\"request_id\":\"unsupported\"") {
                return ["{\"v\":1,\"type\":\"error\",\"reason\":\"unknown_type\"}\n"]
            }
            return ["{\"v\":1,\"type\":\"error\",\"reason\":\"invalid_reply\"}\n"]
        }
        defer { relay.close() }
        let port = try await relay.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
            deviceID: ExactText(identity.deviceID)), transportMode: .relay)
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: relay.rootDER)
        let unsupportedOperationID = UUID()
        let unsupported = try await session.sendOriginalOperation(
            Data(#"{"type":"answer_no_comment","request_id":"unsupported","request_revision":1}"#.utf8)
                + Data([0x0A]),
            operationID: unsupportedOperationID)
        XCTAssertEqual(unsupported, .unsupported(operationID: unsupportedOperationID),
                       "The v0.1.9 unknown_type capability failure keeps its existing Inbox recovery path.")

        let operationID = UUID()
        let result = try await session.sendOriginalOperation(
            Data(#"{"type":"answer_no_comment","request_id":"request","request_revision":1}"#.utf8)
                + Data([0x0A]),
            operationID: operationID)
        XCTAssertEqual(result, .failed(operationID: operationID),
                       "A correlated error other than capability, closed, or stale revision is a definite refusal.")
        await session.close()
    }

    func testStaleNoCommentRevisionRefusalNamesTheCurrentRevision() async throws {
        let namespace = "Harklight.no-comment-stale-revision-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let relay = try LocalRelayWebSocket(expectedDevice: identity.deviceID) { text in
            guard text.contains("\"type\":\"answer_no_comment\"") else { return [] }
            guard text.contains("\"request_revision\":2") else {
                return ["{\"v\":1,\"type\":\"error\",\"reason\":\"unsupported_version\"}\n"]
            }
            return ["{\"v\":1,\"type\":\"error\",\"reason\":\"stale_revision\",\"field\":\"request_revision\",\"current_revision\":3}\n"]
        }
        defer { relay.close() }
        let port = try await relay.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
            deviceID: ExactText(identity.deviceID)), transportMode: .relay)
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: relay.rootDER)
        let operationID = UUID()
        let result = try await session.sendOriginalOperation(
            Data(#"{"type":"answer_no_comment","request_id":"request","request_revision":2}"#.utf8)
                + Data([0x0A]),
            operationID: operationID)
        XCTAssertEqual(result, .staleRevision(operationID: operationID, currentRevision: 3),
                       "The current revision lets the inbox show the changed question and release this answer for retry.")
        await session.close()
    }

    func testUnavailableChatMessageIsLocalToConversationAndDoesNotHideConnectionWarning() throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
            personID: ExactText("person"), deviceID: ExactText("device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let availability = NativeConversationAvailability()
        let presentation = try LivePresentationStore(store: domain, context: context,
                                                     conversationAvailability: availability)
        availability.unavailableContext = context
        presentation.applyRefreshResult(NativeRelayRefreshResult(relayConfirmed: true,
            pushRegistration: .confirmed, confirmedContext: context, confirmedTransportAttemptID: UUID()))
        XCTAssertEqual(presentation.conversationUnavailableMessage, "Chat is not available on this server yet.")
        XCTAssertNil(presentation.connectionWarning)
        XCTAssertNil(presentation.pushRegistrationWarning)
        presentation.applyRefreshResult(.unavailable)
        XCTAssertNotNil(presentation.connectionWarning, "A real refresh failure must still warn even when chat is unavailable.")
        availability.unavailableContext = nil
        XCTAssertNil(presentation.conversationUnavailableMessage, "A replacement connection clears the old refusal.")
    }

    func testLiveConversationFrameDuringInboxPagingKeepsTheRelayOpen() async throws {
        let namespace = "Harklight.relay-live-conversation-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let live: @Sendable (Int) -> String = { seq in
            "{\"v\":1,\"type\":\"conversation\",\"conversation_seq\":\(seq)}\n"
        }
        let relay = try LocalRelayWebSocket(expectedDevice: identity.deviceID) { text in
            if text.contains("\"inbox_attach\"") {
                return ["{\"v\":1,\"type\":\"ok\",\"ref\":\"attach\",\"paging_version\":1,"
                            + "\"checkpoint_accepted\":true,\"replay_started\":true}\n",
                        "{\"v\":1,\"type\":\"resynced\"}\n",
                        live(5)]
            }
            if text.contains("\"inbox_page\"") {
                return [live(6), "{\"v\":1,\"type\":\"ok\",\"ref\":\"page\"}\n"]
            }
            if text.contains("\"conversation_sync\"") {
                return ["{\"v\":1,\"type\":\"ok\",\"ref\":\"native-conversation-sync\"}\n",
                        live(5), live(6),
                        "{\"v\":1,\"type\":\"conversation_resynced\",\"conversation_seq\":6}\n"]
            }
            return []
        }
        defer { relay.close() }
        let port = try await relay.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
            deviceID: ExactText(identity.deviceID)), transportMode: .relay)
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: relay.rootDER)

        try await session.attachInboxReplay(Data("{\"v\":1,\"type\":\"inbox_attach\",\"ref\":\"attach\"}\n".utf8),
                                            ref: "attach") { _ in }
        // A live reply while nothing is reading the socket signals the core
        // without leaving a frame for the next exchange to read.
        try await session.nextLiveConversationSignal()
        // A live reply while an inbox page is pending does not reach the page reader.
        let page = try await session.inboxRequest(Data("{\"v\":1,\"type\":\"inbox_page\",\"ref\":\"page\"}\n".utf8),
                                                  ref: "page")
        XCTAssertEqual(try JSONValue.parse(page).uniqueValue(named: "ref")?.stringValue?.rawValue, "page")
        try await session.nextLiveConversationSignal()
        // The replay the signal starts reads both replies from the durable cursor.
        let frames = ConversationFrameCollector()
        try await session.openConversation(
            Data("{\"v\":1,\"type\":\"conversation_sync\",\"ref\":\"native-conversation-sync\"}\n".utf8)
        ) { frames.append($0) }
        XCTAssertEqual(frames.types, ["ok", "conversation", "conversation", "conversation_resynced"])
        await session.close()
    }

    func testLongConversationCatchUpWithASlowConsumerDeliversEveryEntryInOrder() async throws {
        let namespace = "Harklight.relay-conversation-catch-up-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let backlog = 200
        let relay = try LocalRelayWebSocket(expectedDevice: identity.deviceID) { text in
            if text.contains("\"inbox_attach\"") {
                return ["{\"v\":1,\"type\":\"ok\",\"ref\":\"attach\",\"paging_version\":1,"
                            + "\"checkpoint_accepted\":true,\"replay_started\":true}\n",
                        "{\"v\":1,\"type\":\"resynced\"}\n"]
            }
            if text.contains("\"conversation_sync\"") {
                return ["{\"v\":1,\"type\":\"ok\",\"ref\":\"native-conversation-sync\"}\n"]
                    + (1...backlog).map { "{\"v\":1,\"type\":\"conversation\",\"conversation_seq\":\($0)}\n" }
                    + ["{\"v\":1,\"type\":\"conversation_resynced\",\"conversation_seq\":\(backlog)}\n"]
            }
            return []
        }
        defer { relay.close() }
        let port = try await relay.start()
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText("localhost"), personID: ExactText("test-person"),
            deviceID: ExactText(identity.deviceID)), transportMode: .relay)
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: relay.rootDER)

        try await session.attachInboxReplay(Data("{\"v\":1,\"type\":\"inbox_attach\",\"ref\":\"attach\"}\n".utf8),
                                            ref: "attach") { _ in }
        // The relay sends the whole backlog at once while each entry takes a
        // while to commit, so the reader runs ahead of the replay.
        let frames = ConversationFrameCollector()
        try await session.openConversation(
            Data("{\"v\":1,\"type\":\"conversation_sync\",\"ref\":\"native-conversation-sync\"}\n".utf8)
        ) { frame in
            frames.append(frame)
            frames.noteQueued(await session.queuedResponseFrameCount)
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(frames.types.first, "ok")
        XCTAssertEqual(frames.types.last, "conversation_resynced")
        XCTAssertEqual(frames.conversationSeqs, Array(1...backlog))
        // At most the next entry and the end frame wait behind the consumer.
        XCTAssertLessThanOrEqual(frames.maxQueued, 2)
        await session.close()
    }

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
        let diagnosticEvents = NativeDiagnosticEventCollector()
        let session = try URLSessionInstallationSession(
            profile: context, relayURL: XCTUnwrap(URL(string: "wss://localhost:\(port)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity.value), trustedRootDER: original.rootDER,
            onDiagnostic: { diagnosticEvents.append($0) })
        do {
            try await session.resync(Data("{}\n".utf8)) { _ in }
            XCTFail("A redirect cannot establish the authenticated relay")
        } catch {}
        await session.close()
        XCTAssertTrue(original.receivedRequest, "The original pinned relay received the connection")
        XCTAssertFalse(target.receivedRequest, "The authenticated request must not reach a redirected endpoint")
        XCTAssertTrue(diagnosticEvents.events.contains {
            $0.phase == .ordinaryReplay && $0.transition == .failed && $0.causeCode != nil
        }, "The actual failed relay boundary should remain visible with a safe cause code.")
        XCTAssertTrue(diagnosticEvents.events.contains {
            $0.phase == .relayAdmission && $0.transition == .rejected &&
                $0.causeCode == "relay_redirect_refused"
        }, "An authentication-preserving redirect refusal should report its actual policy cause.")
    }

    func testGibsonEndpointMigrationKeepsTheApprovedProfileAndTrust() throws {
        let namespace = "Harklight.endpoint-migration-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
        defer {
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
        }
        let tlsFixture = try LocalEnrollmentTLS(expectedDevice: identity.deviceID)
        defer { tlsFixture.close() }
        let original = NativeEnrollmentRecord(
            host: NativeEndpointMigrationPolicy.sourceHost,
            enrollmentPort: 18_444,
            relayPort: 18_443,
            trustedRootDER: tlsFixture.rootDER,
            identityLabel: identity.label,
            deviceLabel: "My phone",
            deviceID: identity.deviceID,
            approvalCode: "ABCDEF2345",
            statusSecret: String(repeating: "a", count: 64),
            expiresAt: 2_000,
            statusExpiresAt: 3_000,
            personID: "same-person",
            pushBinding: NativePushBinding(
                address: "push-address",
                operationID: UUID(uuidString: "8D5441E6-1942-47B3-A872-6D9F070BA131")!,
                revision: 7,
                accepted: false),
            serverDisplayName: "Original server",
            accountDisplayName: "Original account",
            notificationExplanationSeen: true,
            foregroundRelayConfirmed: true)
        let enrollment = NativeEnrollmentStore(service: namespace)
        try enrollment.retainApprovedGuided(original, expectedPersonID: "same-person",
                                           expectedDeviceID: identity.deviceID)

        let encodedLegacyRecord = try JSONEncoder().encode(original)
        var legacyObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encodedLegacyRecord) as? [String: Any])
        legacyObject.removeValue(forKey: "localProfileAuthority")
        let decodedLegacyRecord = try JSONDecoder().decode(
            NativeEnrollmentRecord.self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        XCTAssertEqual(decodedLegacyRecord.profileAuthority, NativeEndpointMigrationPolicy.sourceHost,
                       "Older saved enrollments keep their original profile authority")

        XCTAssertEqual(NativeEndpointMigrationPolicy.pinnedRootSHA256,
                       "a550a50ddc8c5286a403b5f71fd7ff2c74f6c862815def1c0666bea2500cf7ea")
        XCTAssertThrowsError(try NativeEndpointMigrationPolicy.candidate(from: original),
                             "A test CA cannot authorize a production endpoint move")
        var wrongEndpoint = original
        wrongEndpoint.host = "unapproved.example"
        XCTAssertThrowsError(try NativeEndpointMigrationPolicy.candidate(
            from: wrongEndpoint, acceptedRootSHA256: NativeEndpointMigrationPolicy.rootSHA256(original.trustedRootDER)))
        var wrongAuthority = original
        wrongAuthority.localProfileAuthority = "unapproved.example"
        XCTAssertThrowsError(try NativeEndpointMigrationPolicy.candidate(
            from: wrongAuthority, acceptedRootSHA256: NativeEndpointMigrationPolicy.rootSHA256(original.trustedRootDER)))
        let fixtureFingerprint = NativeEndpointMigrationPolicy.rootSHA256(original.trustedRootDER)
        var wrongPorts = original
        wrongPorts.relayPort += 1
        XCTAssertThrowsError(try NativeEndpointMigrationPolicy.candidate(
            from: wrongPorts, acceptedRootSHA256: fixtureFingerprint))
        let migrated = try NativeEndpointMigrationPolicy.candidate(from: original,
                                                                    acceptedRootSHA256: fixtureFingerprint)
        XCTAssertEqual(migrated.host, NativeEndpointMigrationPolicy.gibsonHost)
        XCTAssertEqual(migrated.enrollmentPort, original.enrollmentPort,
                       "Migration retains the enrolled port tuple")
        XCTAssertEqual(migrated.relayPort, original.relayPort,
                       "Migration retains the enrolled port tuple")
        XCTAssertEqual(migrated.profileAuthority, NativeEndpointMigrationPolicy.sourceHost)
        var expectedMigration = original
        expectedMigration.host = NativeEndpointMigrationPolicy.gibsonHost
        expectedMigration.localProfileAuthority = NativeEndpointMigrationPolicy.sourceHost
        XCTAssertEqual(migrated, expectedMigration,
                       "Only the transport hostname and explicit stable profile authority change")
        XCTAssertEqual(migrated.personID, original.personID)
        XCTAssertEqual(migrated.deviceID, original.deviceID)
        XCTAssertEqual(migrated.identityLabel, original.identityLabel)
        XCTAssertEqual(migrated.trustedRootDER, original.trustedRootDER)

        var wrongReplacement = migrated
        wrongReplacement.host = "unapproved.example"
        XCTAssertThrowsError(try enrollment.commitGibsonEndpointMigration(
            from: original, to: wrongReplacement, acceptedRootSHA256: fixtureFingerprint))

        try enrollment.commitGibsonEndpointMigration(from: original, to: migrated,
                                                     acceptedRootSHA256: fixtureFingerprint)
        let stored = try XCTUnwrap(enrollment.load())
        XCTAssertEqual(stored, migrated)
        let material = try enrollment.material(from: stored)
        XCTAssertEqual(material.context.identity.trustedRelayAuthority.rawValue,
                       NativeEndpointMigrationPolicy.sourceHost)
        XCTAssertEqual(material.context.identity.personID.rawValue, original.personID)
        XCTAssertEqual(material.context.identity.deviceID.rawValue, original.deviceID)
        XCTAssertEqual(material.relayURL.host, NativeEndpointMigrationPolicy.gibsonHost)
        XCTAssertEqual(material.relayURL.port, NativeEndpointMigrationPolicy.gibsonRelayPort)
        XCTAssertEqual(material.trustedRootDER, original.trustedRootDER)
        var retainedCertificate: SecCertificate?
        XCTAssertEqual(SecIdentityCopyCertificate(material.keychainIdentity, &retainedCertificate), errSecSuccess)
        XCTAssertEqual(SecCertificateCopyData(try XCTUnwrap(retainedCertificate)) as Data,
                       identity.certificateDER)

        let storageRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Harklight.endpoint-migration-files." + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: storageRoot) }
        let sourceFile = storageRoot.appendingPathComponent("saved-attachment.txt")
        let savedBytes = Data("retained local attachment".utf8)
        try FileManager.default.createDirectory(at: storageRoot, withIntermediateDirectories: true)
        try savedBytes.write(to: sourceFile)
        let originalFiles = try ConversationFileStorage(identity: material.context.identity, root: storageRoot)
        let retainedFile = try originalFiles.retain(sourceFile)
        let reopenedFiles = try ConversationFileStorage(identity: material.context.identity, root: storageRoot)
        XCTAssertEqual(try Data(contentsOf: reopenedFiles.fileURL(for: retainedFile)), savedBytes,
                       "The stable profile authority keeps local attachment copies reachable")
    }

    func testInboxRetryUsesCommittedMigrationAfterIncompleteOldEndpointRecovery() async throws {
        let service = "Harklight.endpoint-migration-retry-test." + UUID().uuidString
        let identity = try NativeInstallationIdentityStore(namespace: service).loadOrCreate()
        let tlsFixture = try LocalEnrollmentTLS(expectedDevice: identity.deviceID)
        defer {
            tlsFixture.close()
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassCertificate,
                           kSecAttrLabel as String: identity.label] as CFDictionary)
            SecItemDelete([kSecClass as String: kSecClassKey,
                           kSecAttrApplicationTag as String: Data(service.utf8)] as CFDictionary)
        }

        let operationID = UUID()
        let original = NativeEnrollmentRecord(
            host: NativeEndpointMigrationPolicy.sourceHost,
            enrollmentPort: NativeEndpointMigrationPolicy.gibsonEnrollmentPort,
            relayPort: NativeEndpointMigrationPolicy.gibsonRelayPort,
            trustedRootDER: tlsFixture.rootDER,
            identityLabel: identity.label,
            deviceLabel: "My phone",
            deviceID: identity.deviceID,
            approvalCode: "ABCDEF2345",
            statusSecret: String(repeating: "b", count: 64),
            expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 600_000,
            statusExpiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 900_000,
            personID: "same-person",
            pushBinding: NativePushBinding(address: "saved-push-address", operationID: operationID,
                                           revision: 12, accepted: false),
            serverDisplayName: "Saved server",
            accountDisplayName: "Saved account",
            notificationExplanationSeen: true,
            foregroundRelayConfirmed: true)
        let enrollment = NativeEnrollmentStore(service: service)
        try enrollment.retainApprovedGuided(original, expectedPersonID: "same-person",
                                             expectedDeviceID: identity.deviceID)
        let join = NativeGuidedJoinStore(namespace: service)
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText(original.profileAuthority),
            personID: ExactText(original.personID!), deviceID: ExactText(original.deviceID)),
            transportMode: .relay)
        let domain = try AttentionDomainStore(context: context,
                                             persistence: MemoryAttentionStatePersistence())
        let presentation = try LivePresentationStore(store: domain, context: context)
        let app = NativeAppLaunch(arguments: ["Harklight"], enrollmentStore: enrollment,
                                  joinStore: join, initialState: .live(presentation),
                                  initialEnrollmentRecord: original)

        var attemptedRecords: [NativeEnrollmentRecord] = []
        app.guidedJoin.connectApproved = { record in
            attemptedRecords.append(record)
            return false
        }

        await app.guidedJoin.restore()
        XCTAssertEqual(attemptedRecords, [original], "The established account first attempts recovery at its saved endpoint.")
        XCTAssertEqual(app.guidedJoin.currentAccount, original)
        XCTAssertEqual(app.guidedJoin.screen, .approvedFinishing)
        XCTAssertFalse(app.guidedJoin.isShowing, "An incomplete established-account recovery leaves the ordinary inbox available.")

        let fixtureFingerprint = NativeEndpointMigrationPolicy.rootSHA256(tlsFixture.rootDER)
        let migrated = try NativeEndpointMigrationPolicy.candidate(from: original,
                                                                    acceptedRootSHA256: fixtureFingerprint)
        XCTAssertTrue(app.canApplyPersistedEndpointMigration(from: original, to: migrated))
        try enrollment.commitGibsonEndpointMigration(from: original, to: migrated,
                                                     acceptedRootSHA256: fixtureFingerprint)
        app.applyPersistedEndpointMigration(migrated)

        XCTAssertEqual(try enrollment.load(), migrated, "The fixed-endpoint migration is durably committed first.")
        XCTAssertEqual(app.activeEnrollmentRecord, migrated)
        XCTAssertEqual(app.guidedJoin.currentAccount, migrated,
                       "The visible Retry authority follows the same persisted migrated record.")
        XCTAssertEqual(migrated.personID, original.personID)
        XCTAssertEqual(migrated.deviceID, original.deviceID)
        XCTAssertEqual(migrated.identityLabel, original.identityLabel)
        XCTAssertEqual(migrated.trustedRootDER, original.trustedRootDER)
        XCTAssertEqual(migrated.profileAuthority, original.profileAuthority)
        XCTAssertEqual(migrated.pushBinding, original.pushBinding,
                       "Migration preserves the original device operation and revision binding.")

        await app.retryForegroundConnection()
        XCTAssertEqual(attemptedRecords.map(\.host), [NativeEndpointMigrationPolicy.sourceHost,
                                                       NativeEndpointMigrationPolicy.gibsonHost],
                       "The ordinary inbox Retry uses the validated and persisted migrated endpoint.")
        XCTAssertEqual(attemptedRecords.last?.deviceID, original.deviceID)
        XCTAssertEqual(app.guidedJoin.currentAccount, migrated)
        XCTAssertEqual(try enrollment.load(), migrated,
                       "Retry does not restore the stale old-host enrollment record.")
    }

    func testConversationOriginUsesTheNewEndpointWithoutChangingProfileAuthority() throws {
        let context = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: ExactText(NativeEndpointMigrationPolicy.sourceHost),
            personID: ExactText("same-person"), deviceID: ExactText("same-device")), transportMode: .relay)
        let wire = try ConversationWire(profile: context,
                                        endpointHost: NativeEndpointMigrationPolicy.gibsonHost)
        let accepted = Data("{\"v\":1,\"type\":\"ok\",\"ref\":\"native-conversation-sync\",\"origin_https_port\":52117}\n".utf8)
        let origin = try XCTUnwrap(wire.originEndpoint(accepted))
        XCTAssertEqual(origin.host, NativeEndpointMigrationPolicy.gibsonHost)
        XCTAssertEqual(origin.port, 52_117, "The origin TLS port remains relay-discovered")
        XCTAssertEqual(context.identity.trustedRelayAuthority.rawValue,
                       NativeEndpointMigrationPolicy.sourceHost)

        let mismatchedOrigin = try XCTUnwrap(URL(string: "https://\(NativeEndpointMigrationPolicy.sourceHost):18447/origin/v1"))
        XCTAssertThrowsError(try ConversationFileWire(profile: context, originURL: mismatchedOrigin,
                                                       endpointHost: NativeEndpointMigrationPolicy.gibsonHost))
    }

    func testReadOnlyArchiveKeepsDiscussionAndDraftButBlocksConversationMutationAndNetworkFetch() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("archive-authority"),
            personID: ExactText("archive-person"), deviceID: ExactText("archive-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let storage = try ConversationFileStorage(identity: identity)
        defer { try? storage.removeAccountFiles() }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bytes = Data("saved discussion file".utf8)
        try bytes.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let localFile = try storage.retain(source)
        let remoteFile = ConversationFile(id: ExactText("not-downloaded"), name: ExactText("remote.txt"),
            byteCount: 6, sha256: ExactText(String(repeating: "a", count: 64)),
            content: .uploaded(ExactText(UUID().uuidString.lowercased())))

        let persistence = MemoryAttentionStatePersistence()
        let domain = try AttentionDomainStore(context: context, persistence: persistence,
            conversationFileReferences: storage)
        let key = RequestKey(accountScope: identity.personID, senderID: ExactText("sender"),
                             messageID: ExactText("archived-request"))
        let binding = ConversationBinding(request: key, revision: 1)
        let payload = try JSONValue.parse(Data(#"{"title":"Retained request"}"#.utf8))
        try domain.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"),
                                                     eventID: ExactText("delivery"))), context: context)
        try domain.applyConversation(ConversationEvent(sequence: 1, binding: binding,
            fact: .request(sessionHandle: ExactText("session"), payload: payload)), context: context)
        let savedDraft = ConversationDraft(binding: binding, text: ExactText("Keep this discussion draft"),
                                           files: [localFile])
        try domain.saveConversationDraft(savedDraft, context: context)
        let turn = ConversationTurn(id: ExactText("retained-turn"), binding: binding, author: .person,
            sessionHandle: ExactText("session"), text: ExactText("Earlier discussion wording"),
            files: [localFile, remoteFile])
        try domain.applyConversation(ConversationEvent(sequence: 2, binding: binding, fact: .turn(turn)), context: context)
        let uploadOperation = try domain.prepareDiscussion(binding, context: context)
        try domain.registerConversationUpload(localFile, binding: binding, operation: uploadOperation, context: context)
        try domain.markDiscussionOutcome(binding, operation: uploadOperation,
                                         rejection: ExactText("No live submission"), context: context)
        let before = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
        let persistedBefore = try XCTUnwrap(persistence.load(identity: identity))

        let archive = try LivePresentationStore(disconnectedStore: domain, context: context)
        XCTAssertTrue(archive.isReadOnly)
        XCTAssertFalse(archive.isLocalExample, "A real account archive is not a fictional sample")
        XCTAssertEqual(archive.conversation(for: key)?.turns.first(where: { $0.id == turn.id })?.text, turn.text)
        XCTAssertEqual(archive.conversationDraft(for: key, revision: 1).text, savedDraft.text)
        let cachedURL = try await archive.prepareConversationPreview(localFile)
        XCTAssertEqual(cachedURL, try storage.fileURL(for: localFile),
                       "An already retained file stays locally openable")
        do {
            _ = try await archive.prepareConversationPreview(remoteFile)
            XCTFail("A read-only archive cannot fetch a file absent from its local cache")
        } catch {}

        archive.navigateMessage(from: key, to: nil)
        archive.updateConversation(for: key, revision: 1, text: "Must remain unchanged")
        archive.updateConversation(for: key, revision: 1, files: [])
        archive.addLocalAttachment("Fictional file", for: key, revision: 1)
        archive.sendDiscussion(for: key, revision: 1)

        let after = try XCTUnwrap(domain.conversationSnapshot(context: context).threads[key])
        XCTAssertEqual(after, before, "Archive navigation and blocked controls do not change draft, turns, or cleanup state")
        XCTAssertTrue(after.uploadCleanups?.isEmpty ?? true, "Browsing an archive does not create upload cleanup")
        XCTAssertTrue(try domain.snapshot(context: context).outbox.isEmpty)
        XCTAssertTrue(try domain.snapshot(context: context).intents.isEmpty)
        XCTAssertEqual(try XCTUnwrap(persistence.load(identity: identity)), persistedBefore)
    }

    func testLaterDisconnectsKeepEveryEarlierConfirmedAccountArchiveDiscoverable() async throws {
        let service = "Harklight.departure-archive-test." + UUID().uuidString
        let transport = ArchiveRemovalTransport()
        let join = NativeGuidedJoinStore(namespace: service, transport: transport)
        let enrollment = NativeEnrollmentStore(service: service)
        let tlsFixture = try LocalEnrollmentTLS(expectedDevice: nil)
        defer {
            tlsFixture.close()
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }

        func makeRecord(_ label: String, _ person: String) throws -> (String, NativeEnrollmentRecord) {
            let namespace = service + "." + label
            let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
            let record = NativeEnrollmentRecord(host: NativeEndpointMigrationPolicy.sourceHost,
                enrollmentPort: NativeEndpointMigrationPolicy.gibsonEnrollmentPort,
                relayPort: NativeEndpointMigrationPolicy.gibsonRelayPort,
                trustedRootDER: tlsFixture.rootDER, identityLabel: identity.label, deviceLabel: label,
                deviceID: identity.deviceID, approvalCode: "ABCDEF2345",
                statusSecret: String(repeating: "b", count: 64), expiresAt: 2_000,
                statusExpiresAt: 3_000, personID: person, serverDisplayName: "Server",
                accountDisplayName: label, notificationExplanationSeen: true,
                foregroundRelayConfirmed: true)
            return (namespace, record)
        }

        let identities = try [makeRecord("Account A", "person-a"),
                              makeRecord("Account B", "person-b"),
                              makeRecord("Account C", "person-c")]
        transport.peopleByDevice = Dictionary(uniqueKeysWithValues: identities.compactMap { item in
            item.1.personID.map { (item.1.deviceID, $0) }
        })
        defer {
            for (namespace, record) in identities {
                SecItemDelete([kSecClass as String: kSecClassCertificate,
                               kSecAttrLabel as String: record.identityLabel] as CFDictionary)
                SecItemDelete([kSecClass as String: kSecClassKey,
                               kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
            }
        }

        let first = identities[0].1
        try enrollment.retainApprovedGuided(first, expectedPersonID: "person-a", expectedDeviceID: first.deviceID)
        try join.prepareAccountDeparture(first)
        try await join.removeCurrentAccount(first)
        try enrollment.retainApprovedGuided(identities[1].1, expectedPersonID: "person-b",
                                             expectedDeviceID: identities[1].1.deviceID)
        try join.prepareAccountDeparture(identities[1].1)
        XCTAssertEqual(try join.archivedDepartures().map(\.record.deviceID), [first.deviceID])

        try await join.removeCurrentAccount(identities[1].1)
        try enrollment.retainApprovedGuided(identities[2].1, expectedPersonID: "person-c",
                                             expectedDeviceID: identities[2].1.deviceID)
        try join.prepareAccountDeparture(identities[2].1)
        let reopened = NativeGuidedJoinStore(namespace: service, transport: transport)
        let archives = try reopened.archivedDepartures()
        XCTAssertEqual(archives.map(\.record.deviceID), [first.deviceID, identities[1].1.deviceID])
        XCTAssertEqual(archives.compactMap(\.record.personID), ["person-a", "person-b"])
        XCTAssertTrue(archives.allSatisfy { $0.removed && $0.replacement == nil })
    }

    func testReplacementRefreshesArchiveCatalogAndRestoredCurrentAccountCanReturnFromArchive() async throws {
        let service = "Harklight.replacement-archive-navigation-test." + UUID().uuidString
        let transport = ArchiveRemovalTransport()
        let join = NativeGuidedJoinStore(namespace: service, transport: transport)
        let enrollment = NativeEnrollmentStore(service: service)
        let tlsFixture = try LocalEnrollmentTLS(expectedDevice: nil)
        defer {
            tlsFixture.close()
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }

        func makeRecord(_ label: String, _ person: String) throws -> NativeEnrollmentRecord {
            let namespace = service + "." + label
            let identity = try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate()
            let record = NativeEnrollmentRecord(host: NativeEndpointMigrationPolicy.sourceHost,
                enrollmentPort: NativeEndpointMigrationPolicy.gibsonEnrollmentPort,
                relayPort: NativeEndpointMigrationPolicy.gibsonRelayPort,
                trustedRootDER: tlsFixture.rootDER, identityLabel: identity.label, deviceLabel: label,
                deviceID: identity.deviceID, approvalCode: "ABCDEF2345",
                statusSecret: String(repeating: "c", count: 64), expiresAt: 2_000,
                statusExpiresAt: 3_000, personID: person, serverDisplayName: "Server",
                accountDisplayName: label, notificationExplanationSeen: true,
                foregroundRelayConfirmed: true)
            return record
        }

        let original = try makeRecord("Original", "person-original")
        let replacement = try makeRecord("Replacement", "person-replacement")
        let originalNamespace = service + ".Original"
        let replacementNamespace = service + ".Replacement"
        defer {
            for (record, namespace) in [(original, originalNamespace), (replacement, replacementNamespace)] {
                SecItemDelete([kSecClass as String: kSecClassCertificate,
                               kSecAttrLabel as String: record.identityLabel] as CFDictionary)
                SecItemDelete([kSecClass as String: kSecClassKey,
                               kSecAttrApplicationTag as String: Data(namespace.utf8)] as CFDictionary)
            }
        }
        transport.peopleByDevice = [original.deviceID: "person-original"]
        try enrollment.retainApprovedGuided(original, expectedPersonID: "person-original",
                                             expectedDeviceID: original.deviceID)

        func presentation(for record: NativeEnrollmentRecord) throws -> LivePresentationStore {
            let context = ProfileContext(identity: ProfileIdentity(
                trustedRelayAuthority: ExactText(record.profileAuthority),
                personID: ExactText(record.personID!), deviceID: ExactText(record.deviceID)),
                transportMode: .relay)
            let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
            return try LivePresentationStore(store: domain, context: context)
        }

        let invitationRoot = "-----BEGIN CERTIFICATE-----\n" +
            tlsFixture.rootDER.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed]) +
            "-----END CERTIFICATE-----\n"
        let invitation = NativeJoinInvitation(v: 1, personID: "person-replacement", serverName: "localhost",
            enrollmentURL: URL(string: "https://localhost:18444/enroll")!,
            relayURL: URL(string: "wss://localhost:18443/relay")!, caPEM: invitationRoot,
            caSHA256: NativeEndpointMigrationPolicy.rootSHA256(tlsFixture.rootDER),
            inviteToken: String(repeating: "d", count: 64),
            expiresAt: Int64(Date().timeIntervalSince1970 * 1_000) + 60_000,
            personName: "Replacement", inviterName: "Owner")
        let encodedInvitation = try JSONEncoder().encode(invitation)
        let fragment = encodedInvitation.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let invitationURL = try XCTUnwrap(URL(string: "harklight://join#\(fragment)"))

        let originalPresentation = try presentation(for: original)
        let app = NativeAppLaunch(arguments: ["Harklight"], enrollmentStore: enrollment,
            joinStore: join, initialState: .live(originalPresentation), initialEnrollmentRecord: original)
        await app.receiveInvitation(invitationURL)
        XCTAssertEqual(app.guidedJoin.screen, .existingAccount)
        app.guidedJoin.considerReplacement()
        await app.guidedJoin.confirmReplacement()
        XCTAssertEqual(app.guidedJoin.screen, .confirmation)
        XCTAssertNil(app.activeEnrollmentRecord)
        XCTAssertEqual(app.archivedAccountDepartures.map(\.record.deviceID), [original.deviceID],
                       "The confirmed replacement callback refreshes the catalog in the same process")

        // Model the next approved enrollment after replacement without connecting
        // a relay. Its archive catalog comes from the persisted join store.
        try join.dismissConfirmedDeparture()
        try enrollment.retainApprovedGuided(replacement, expectedPersonID: "person-replacement",
                                             expectedDeviceID: replacement.deviceID)
        let reopenedJoin = NativeGuidedJoinStore(namespace: service, transport: transport)
        let currentPresentation = try presentation(for: replacement)
        let restored = NativeAppLaunch(arguments: ["Harklight"], enrollmentStore: enrollment,
            joinStore: reopenedJoin, initialState: .live(currentPresentation),
            initialEnrollmentRecord: replacement)
        restored.guidedJoin.connectApproved = { _ in false }
        await restored.restoreInstallation()

        XCTAssertEqual(restored.activeEnrollmentRecord, replacement)
        XCTAssertFalse(restored.guidedJoin.isShowing)
        XCTAssertEqual(restored.archivedAccountDepartures.map(\.record.deviceID), [original.deviceID],
                       "The confirmed archive remains discoverable after restoration with a current account")
        let archived = try XCTUnwrap(restored.archivedAccountDepartures.first)
        restored.showArchivedAccount(archived)
        XCTAssertEqual(restored.selectedArchivedAccount?.record.deviceID, original.deviceID)
        XCTAssertTrue(restored.selectedArchivedPresentation?.isReadOnly == true)
        XCTAssertTrue(restored.inboxPresentation === currentPresentation)

        restored.showCurrentAccount()
        XCTAssertNil(restored.selectedArchivedAccount)
        XCTAssertNil(restored.selectedArchivedPresentation)
        XCTAssertTrue(restored.inboxPresentation === currentPresentation,
                      "Returning from the archive reveals the still-enrolled account")
    }

    func testForegroundFailureDismissalSurvivesArchiveNavigationAndIsScopedToAccountAndAttempt() throws {
        let service = "Harklight.foreground-failure-dismissal-test." + UUID().uuidString
        defer {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service] as CFDictionary)
        }

        func makeRecord(_ personID: String, _ deviceID: String) -> NativeEnrollmentRecord {
            NativeEnrollmentRecord(host: "relay.example", enrollmentPort: 18444, relayPort: 18443,
                trustedRootDER: Data("test-root".utf8), identityLabel: "test-identity-\(deviceID)",
                deviceLabel: deviceID, deviceID: deviceID, approvalCode: "unused",
                statusSecret: "unused", expiresAt: 0, statusExpiresAt: 0, personID: personID)
        }

        func makePresentation(for record: NativeEnrollmentRecord) throws -> LivePresentationStore {
            let context = ProfileContext(identity: ProfileIdentity(
                trustedRelayAuthority: ExactText(record.profileAuthority),
                personID: ExactText(record.personID!), deviceID: ExactText(record.deviceID)),
                transportMode: .relay)
            let domain = try AttentionDomainStore(context: context,
                persistence: MemoryAttentionStatePersistence())
            return try LivePresentationStore(store: domain, context: context)
        }

        let current = makeRecord("current-person", "current-device")
        let archived = makeRecord("archived-person", "archived-device")
        let departure = NativeAccountDeparture(record: archived, replacement: nil, removed: true)
        let currentPresentation = try makePresentation(for: current)
        let app = NativeAppLaunch(arguments: ["Harklight"],
            enrollmentStore: NativeEnrollmentStore(service: service),
            joinStore: NativeGuidedJoinStore(namespace: service),
            initialState: .live(currentPresentation), initialEnrollmentRecord: current,
            initialArchivedDepartures: [departure])

        var reconnectCalls = 0
        app.guidedJoin.connectApproved = { _ in
            reconnectCalls += 1
            return false
        }

        let operationID = UUID()
        let snapshot = NativeForegroundOperationSnapshot(available: true, operations: [
            NativeForegroundOperationDiagnostic(operationID: operationID, senderID: "sender",
                messageID: "request", requestRevision: 4, receiptState: "unknown")
        ])
        let attemptID = UUID()
        let connecting = NativeForegroundConnectProgress(lastConfirmedStage: .nativeSyncAcknowledged,
            webSocketOpenObserved: true, issue: nil, outcome: .connecting, attemptID: attemptID)
        app.recordForegroundConnectProgress(connecting, operationSnapshot: snapshot)
        XCTAssertNil(app.foregroundConnectFailureKey,
                     "An in-flight retry must not consume or present the attempt's failure details.")
        XCTAssertNil(NativeForegroundConnectFailureKey(record: current, progress: connecting))

        let progress = NativeForegroundConnectProgress(lastConfirmedStage: .nativeSyncAcknowledged,
            webSocketOpenObserved: true, issue: nil, outcome: .timedOut, attemptID: attemptID)
        app.recordForegroundConnectProgress(progress, operationSnapshot: snapshot)
        let failureKey = try XCTUnwrap(app.foregroundConnectFailureKey)
        XCTAssertTrue(app.shouldPresentForegroundConnectFailure(failureKey))

        app.dismissForegroundConnectFailure(failureKey)
        XCTAssertFalse(app.shouldPresentForegroundConnectFailure(failureKey))
        XCTAssertEqual(app.foregroundConnectProgress, progress, "Dismissal keeps the observed failure state.")
        XCTAssertEqual(app.foregroundConnectDiagnostic?.operationSnapshot, snapshot,
                       "Dismissal keeps the original uncertain operation and receipt evidence.")
        XCTAssertEqual(app.activeEnrollmentRecord, current)
        XCTAssertEqual(reconnectCalls, 0, "Dismissing details never retries the connection.")

        app.showArchivedAccount(departure)
        XCTAssertEqual(app.selectedArchivedAccount?.record.deviceID, archived.deviceID)
        XCTAssertTrue(app.selectedArchivedPresentation?.isReadOnly == true)
        XCTAssertFalse(app.shouldPresentForegroundConnectFailure(failureKey),
                       "Rebuilding the inbox for an archive does not forget dismissal.")
        app.showCurrentAccount()
        XCTAssertFalse(app.shouldPresentForegroundConnectFailure(failureKey),
                       "Returning to the active account does not re-force the unchanged failure.")
        XCTAssertEqual(app.foregroundConnectDiagnostic?.operationSnapshot, snapshot)
        XCTAssertEqual(reconnectCalls, 0)

        app.reopenForegroundConnectFailure(failureKey)
        XCTAssertTrue(app.shouldPresentForegroundConnectFailure(failureKey),
                      "Settings can explicitly reopen the same failure details.")
        XCTAssertEqual(reconnectCalls, 0, "Reopening details also does not retry.")

        let nextAttempt = NativeForegroundConnectProgress(lastConfirmedStage: .nativeSyncAcknowledged,
            webSocketOpenObserved: true, issue: nil, outcome: .incomplete, attemptID: UUID())
        app.recordForegroundConnectProgress(nextAttempt, operationSnapshot: snapshot)
        let nextKey = try XCTUnwrap(app.foregroundConnectFailureKey)
        XCTAssertNotEqual(nextKey, failureKey)
        XCTAssertTrue(app.shouldPresentForegroundConnectFailure(nextKey),
                      "A new failed attempt remains eligible for details.")
        let otherAccountKey = try XCTUnwrap(NativeForegroundConnectFailureKey(record: archived,
                                                                              progress: nextAttempt))
        XCTAssertNotEqual(otherAccountKey, nextKey,
                          "The same attempt identifier is distinct under another saved account.")
        app.dismissForegroundConnectFailure(nextKey)
        XCTAssertFalse(app.shouldPresentForegroundConnectFailure(nextKey))
        XCTAssertTrue(app.shouldPresentForegroundConnectFailure(otherAccountKey),
                      "Dismissal is scoped to the original account identity.")
        XCTAssertEqual(reconnectCalls, 0)
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
        XCTAssertEqual(result.headline, "Connection not confirmed")
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
        XCTAssertNotEqual(bundleDiagnostic.appVersion, "unavailable")
        XCTAssertNotEqual(bundleDiagnostic.buildNumber, "unavailable")
        let bundleMetadata = [
            "app_version=\(bundleDiagnostic.appVersion)",
            "app_build=\(bundleDiagnostic.buildNumber)",
            "app_executable_sha256=\(bundleDiagnostic.executableSHA256)"
        ]
        bundleMetadata.forEach { XCTAssertTrue(bundleDiagnostic.shareText.contains($0), $0) }
        print("Connection diagnostics from the installed app bundle:\n\(bundleMetadata.joined(separator: "\n"))")
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

    func testCaughtFilePreviewFailureIsRetrievableWithSafeRequestContext() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("private-person-marker"),
                                       deviceID: ExactText("diagnostic-draft-read-device"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let domain = try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence())
        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightCaughtPreview-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = NativeClientDiagnosticJournal(fileURL: journalURL)
        let presentation = try LivePresentationStore(store: domain, context: context, diagnostics: journal)
        let request = RequestKey(accountScope: identity.personID,
                                 senderID: ExactText("private-sender-marker"),
                                 messageID: ExactText("private-message-marker"))
        let file = ConversationFile(id: ExactText("file-marker"),
            name: ExactText("../private-file-name-marker"), byteCount: 1,
            sha256: ExactText(String(repeating: "a", count: 64)), content: .inline(Data([0x41])))

        do {
            _ = try await presentation.prepareConversationPreview(file, for: request, revision: 7)
            XCTFail("A path-like filename must be refused before any network fetch.")
        } catch {}
        let event = try XCTUnwrap(journal.events.last)
        XCTAssertEqual(event.area, .fileAccess)
        XCTAssertEqual(event.phase, .filePreview)
        XCTAssertEqual(event.transition, .failed)
        XCTAssertEqual(event.causeCode, "conversation_file_mismatch")
        XCTAssertEqual(event.requestRevision, 7)
        XCTAssertNotNil(event.requestTag)
        XCTAssertFalse(journal.shareText.contains("private-person-marker"))
        XCTAssertFalse(journal.shareText.contains("private-sender-marker"))
        XCTAssertFalse(journal.shareText.contains("private-message-marker"))
        XCTAssertFalse(journal.shareText.contains("private-file-name-marker"))

        let importError = NSError(domain: "private-import-path-marker", code: 73,
            userInfo: [NSLocalizedDescriptionKey: "private-picker-url-marker"])
        presentation.reportConversationImportError(importError, for: request, revision: 9)
        let importEvent = try XCTUnwrap(journal.events.last)
        XCTAssertEqual(importEvent.phase, .fileRetention)
        XCTAssertEqual(importEvent.transition, .failed)
        XCTAssertEqual(importEvent.causeCode, "unknown_error")
        XCTAssertEqual(importEvent.requestRevision, 9)
        XCTAssertFalse(journal.shareText.contains("private-import-path-marker"))
        XCTAssertFalse(journal.shareText.contains("private-picker-url-marker"))
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

        let diagnosticEvents = NativeDiagnosticEventCollector()
        let firstTransport = UUID()
        let secondTransport = UUID()
        let firstSession = ForegroundProgressRelaySession(identity: identity, store: store, context: context)
        let firstCore = try NativeRelayCore(store: store, context: context, session: firstSession,
            attemptID: firstTransport, onDiagnostic: { diagnosticEvents.append($0) })
        let firstAttempt = try await firstCore.sendPendingOriginalOperations()
        let secondSession = ForegroundProgressRelaySession(identity: identity, store: store, context: context)
        let secondCore = try NativeRelayCore(store: store, context: context, session: secondSession,
            attemptID: secondTransport, onDiagnostic: { diagnosticEvents.append($0) })
        let secondAttempt = try await secondCore.sendPendingOriginalOperations()
        XCTAssertEqual(firstAttempt, 1)
        XCTAssertEqual(secondAttempt, 1)

        let firstSends = firstSession.originalOperationRecorder.snapshot()
        let secondSends = secondSession.originalOperationRecorder.snapshot()
        let sends = firstSends.operationIDs + secondSends.operationIDs
        XCTAssertEqual(sends, [original.operationID, original.operationID])
        XCTAssertEqual(firstSends.frames + secondSends.frames, [original.wireFrame, original.wireFrame])
        let operationEvents = diagnosticEvents.events.filter {
            $0.phase == .originalOperationDelivery && $0.transition == .unresolved
        }
        XCTAssertEqual(operationEvents.count, 2)
        XCTAssertEqual(Set(operationEvents.compactMap(\.operationID)), [original.operationID])
        XCTAssertEqual(Set(operationEvents.compactMap(\.transportAttemptID)), [firstTransport, secondTransport])
        XCTAssertEqual(Set(operationEvents.compactMap(\.requestRevision)), [1])
        XCTAssertEqual(Set(operationEvents.compactMap(\.receiptState)), [.unknown])
        XCTAssertEqual(Set(operationEvents.compactMap(\.requestTag)).count, 1)
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
        XCTAssertEqual(events.snapshot(), [
            .nativeSyncReplayRequested,
            .nativeSyncResynced,
            .nativeSyncAcknowledged,
            .postAckDrainBegan,
            .postAckDrainFinished(.completed)
        ])

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

        // A follow-on replay can advance the saved cursor while this monotonic
        // milestone still records only the earlier acknowledged checkpoint.
        progress.observe(.nativeSyncReplayRequested, transportAttemptID: transportAttemptID)
        progress.observe(.nativeSyncResynced, transportAttemptID: transportAttemptID)
        var laterReplayAwaitingAck = progress.progress
        laterReplayAwaitingAck.outcome = .incomplete
        XCTAssertTrue(laterReplayAwaitingAck.message.contains("At the last confirmed checkpoint"))
        XCTAssertTrue(laterReplayAwaitingAck.message.contains("whether a later replay advanced the saved cursor"))
        XCTAssertTrue(laterReplayAwaitingAck.message.contains("whether that later cursor was acknowledged"))
        XCTAssertTrue(laterReplayAwaitingAck.message.contains("Full foreground completion remains unconfirmed"))
        XCTAssertFalse(laterReplayAwaitingAck.message.contains("through the saved native cursor were durably applied and that cursor was acknowledged"))

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

    func testCompletedRefreshKeepsItsConfirmedProfileWhileQueuedRefreshBegins() async throws {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"), deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let transportAttemptID = UUID()
        let persistence = MemoryAttentionStatePersistence()
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let session = ForegroundProgressRelaySession(identity: identity, store: store, context: context)
        let core = try NativeRelayCore(store: store, context: context, session: session)
        let (firstStarted, firstStartedSignal) = AsyncStream<Void>.makeStream()
        let (releaseFirst, releaseFirstSignal) = AsyncStream<Void>.makeStream()
        let (callbackQueued, callbackQueuedSignal) = AsyncStream<Void>.makeStream()
        let (secondStarted, secondStartedSignal) = AsyncStream<Void>.makeStream()
        let (releaseSecond, releaseSecondSignal) = AsyncStream<Void>.makeStream()
        var passes = 0
        var currentConfirmation: ProfileContext?
        let flights = RelayRefreshFlights(inactive: NativeRelayRefreshResult.unavailable) {
            passes += 1
            currentConfirmation = nil
            if passes == 1 {
                firstStartedSignal.yield()
                for await _ in releaseFirst { break }
                do { _ = try await core.resyncAndDrainOutbox() }
                catch { XCTFail("The fixture replay must complete: \(error)"); return .unavailable }
                currentConfirmation = context
                return await NativeRelayRefreshResult.afterConfirmedRelay(context: context, transportAttemptID: transportAttemptID) { .notAttempted }
            }
            secondStartedSignal.yield()
            for await _ in releaseSecond { break }
            return .unavailable
        }

        let initial = Task { await flights.coalesced() }
        for await _ in firstStarted { break }
        let callback = Task {
            callbackQueuedSignal.yield()
            return await flights.afterCurrent()
        }
        for await _ in callbackQueued { break }
        releaseFirstSignal.yield()
        // Model the foreground waiter resuming after a normal APNs/answer
        // callback has started its queued refresh, without relying on timing.
        for await _ in secondStarted { break }
        let completed = await initial.value
        XCTAssertNil(currentConfirmation, "The old shared confirmation has already been cleared.")
        XCTAssertTrue(completed.confirms(context, transportAttemptID: transportAttemptID),
                      "Foreground validation must use the completed flight's profile, not the next flight's state.")
        XCTAssertEqual(session.cursorAtAcknowledgement, 1)
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        let saved = try persistence.load(identity: identity)

        let replacementGeneration = ProfileContext(identity: identity, transportMode: .relay)
        XCTAssertFalse(completed.confirms(replacementGeneration, transportAttemptID: transportAttemptID),
                       "Confirmation cannot cross profile generations even for the same device.")
        let differentDevice = ProfileContext(identity: ProfileIdentity(
            trustedRelayAuthority: identity.trustedRelayAuthority, personID: identity.personID,
            deviceID: ExactText("device-B")), generation: context.generation, transportMode: .relay)
        XCTAssertFalse(completed.confirms(differentDevice, transportAttemptID: transportAttemptID))
        XCTAssertFalse(completed.confirms(context, transportAttemptID: UUID()),
                       "A completed refresh cannot confirm a subsequently replaced transport.")
        XCTAssertFalse(completed.confirms(context, transportAttemptID: nil))
        XCTAssertFalse(NativeRelayRefreshResult.unavailable.confirms(context, transportAttemptID: transportAttemptID))

        releaseSecondSignal.yield()
        let later = await callback.value
        XCTAssertFalse(later.confirms(context, transportAttemptID: transportAttemptID), "A later failed refresh cannot borrow the earlier success.")
        XCTAssertTrue(completed.confirms(context, transportAttemptID: transportAttemptID), "A later failure cannot rewrite the earlier result.")
        XCTAssertEqual(try persistence.load(identity: identity), saved)
        await core.deactivate()
    }

    func testConfirmedRefreshRetainsProfileWhenPushRegistrationFails() async {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"), deviceID: ExactText("device-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        let transportAttemptID = UUID()
        let result = await NativeRelayRefreshResult.afterConfirmedRelay(context: context, transportAttemptID: transportAttemptID) {
            throw URLError(.cannotConnectToHost)
        }
        XCTAssertTrue(result.confirms(context, transportAttemptID: transportAttemptID))
        XCTAssertEqual(result.pushRegistration, .unconfirmed)
    }

    func testPostAckForegroundSummaryRetainsBoundaryValidationAndUnknownCause() async throws {
        let transportAttemptID = UUID()
        let failedDeadline = ForegroundConnectDeadline()
        failedDeadline.beginSession(transportAttemptID: transportAttemptID)
        failedDeadline.observe(.nativeSyncAcknowledged, transportAttemptID: transportAttemptID)
        failedDeadline.observe(.postAckDrainBegan, transportAttemptID: transportAttemptID)
        failedDeadline.observe(.postAckDrainFinished(.failed), transportAttemptID: transportAttemptID)
        let failed = await failedDeadline.run(deadline: .seconds(2), operation: {
            failedDeadline.recordPostAckCompletion(postAckReached: true,
                relayRefreshConfirmed: false, generationMatches: false,
                profileMatches: true, relayContextMatches: false)
            return false
        }, onTimeout: {}, onProgress: { _ in })

        XCTAssertEqual(failed.outcome, .incomplete)
        XCTAssertNil(failed.failureClass, "No transport cause was observed in this invalidation case.")
        XCTAssertEqual(failed.terminalReason, .generationInvalidated)
        XCTAssertEqual(failed.lastCompletedPostAckBoundary, .relayRefreshReturned)
        XCTAssertEqual(failed.postAckRelayRefresh, .failed)
        XCTAssertEqual(failed.postAckDrainTransition, .failed)
        XCTAssertEqual(failed.generationValidation, .failed)
        XCTAssertEqual(failed.profileContextValidation, .passed)
        XCTAssertEqual(failed.relayContextValidation, .failed)
        XCTAssertTrue(failed.message.contains("Cause was not observed."))

        let failedSummary = NativeForegroundConnectDiagnostic(
            progress: failed, operationSnapshot: .unavailable,
            appVersion: "4.8.2", buildNumber: "1087",
            executableSHA256: String(repeating: "a", count: 64))
        XCTAssertTrue(failedSummary.shareText.contains("app_version=4.8.2"))
        XCTAssertTrue(failedSummary.shareText.contains("app_build=1087"))
        XCTAssertTrue(failedSummary.shareText.contains("last_completed_post_ack_boundary=post_ack_relay_refresh_returned"))
        XCTAssertTrue(failedSummary.shareText.contains("post_ack_relay_refresh=failed"))
        XCTAssertTrue(failedSummary.shareText.contains("post_ack_drain=failed"))
        XCTAssertTrue(failedSummary.shareText.contains("generation_validated=failed"))
        XCTAssertTrue(failedSummary.shareText.contains("profile_context_validated=passed"))
        XCTAssertTrue(failedSummary.shareText.contains("relay_context_validated=failed"))
        XCTAssertTrue(failedSummary.shareText.contains("terminal_reason=generation_invalidated"))
        XCTAssertTrue(failedSummary.shareText.contains("error_class=unknown_error_class"))

        let successfulDeadline = ForegroundConnectDeadline()
        let successfulTransportID = UUID()
        successfulDeadline.beginSession(transportAttemptID: successfulTransportID)
        successfulDeadline.observe(.nativeSyncAcknowledged, transportAttemptID: successfulTransportID)
        successfulDeadline.observe(.postAckDrainBegan, transportAttemptID: successfulTransportID)
        successfulDeadline.observe(.postAckDrainFinished(.completed), transportAttemptID: successfulTransportID)
        let confirmed = await successfulDeadline.run(deadline: .seconds(2), operation: {
            successfulDeadline.recordPostAckCompletion(postAckReached: true,
                relayRefreshConfirmed: true, generationMatches: true,
                profileMatches: true, relayContextMatches: true)
            return true
        }, onTimeout: {}, onProgress: { _ in })
        XCTAssertEqual(confirmed.outcome, .confirmed)
        XCTAssertEqual(confirmed.terminalReason, .confirmed)
        XCTAssertEqual(confirmed.lastCompletedPostAckBoundary, .foregroundConfirmed)
        XCTAssertEqual(confirmed.postAckDrainTransition, .completed)
        XCTAssertEqual(confirmed.generationValidation, .passed)
        XCTAssertEqual(confirmed.profileContextValidation, .passed)
        XCTAssertEqual(confirmed.relayContextValidation, .passed)

        let timeoutDeadline = ForegroundConnectDeadline()
        let timeoutTransportID = UUID()
        timeoutDeadline.beginSession(transportAttemptID: timeoutTransportID)
        timeoutDeadline.observe(.nativeSyncAcknowledged, transportAttemptID: timeoutTransportID)
        timeoutDeadline.observe(.postAckDrainBegan, transportAttemptID: timeoutTransportID)
        let timedOut = await timeoutDeadline.run(deadline: .milliseconds(20), operation: {
            try? await Task.sleep(for: .seconds(2))
            return false
        }, onTimeout: {}, onProgress: { _ in })
        XCTAssertEqual(timedOut.outcome, .timedOut)
        timeoutDeadline.recordTimedOutValidation(attemptID: try XCTUnwrap(timedOut.attemptID),
            generationMatches: false, profileMatches: true, relayContextMatches: false)
        XCTAssertEqual(timeoutDeadline.progress.terminalReason, .deadlineExceeded)
        XCTAssertEqual(timeoutDeadline.progress.lastCompletedPostAckBoundary, .nativeCursorAcknowledged)
        XCTAssertEqual(timeoutDeadline.progress.postAckRelayRefresh, .failed)
        XCTAssertEqual(timeoutDeadline.progress.postAckDrainTransition, .timedOut)
        XCTAssertEqual(timeoutDeadline.progress.generationValidation, .failed)
        XCTAssertEqual(timeoutDeadline.progress.profileContextValidation, .passed)
        XCTAssertEqual(timeoutDeadline.progress.relayContextValidation, .failed)

        let cancelledDeadline = ForegroundConnectDeadline()
        let cancelledTransportID = UUID()
        cancelledDeadline.beginSession(transportAttemptID: cancelledTransportID)
        cancelledDeadline.observe(.nativeSyncAcknowledged, transportAttemptID: cancelledTransportID)
        cancelledDeadline.observe(.postAckDrainBegan, transportAttemptID: cancelledTransportID)
        cancelledDeadline.observe(.postAckDrainFinished(.cancelled), transportAttemptID: cancelledTransportID)
        let cancelled = await cancelledDeadline.run(deadline: .seconds(2), operation: {
            cancelledDeadline.recordFailure(CancellationError())
            cancelledDeadline.recordPostAckCompletion(postAckReached: true,
                relayRefreshConfirmed: false, generationMatches: true,
                profileMatches: true, relayContextMatches: false)
            return false
        }, onTimeout: {}, onProgress: { _ in })
        XCTAssertEqual(cancelled.outcome, .incomplete)
        XCTAssertEqual(cancelled.failureClass, .cancelled)
        XCTAssertEqual(cancelled.terminalReason, .cancelled)

        let lateProgressDeadline = ForegroundConnectDeadline()
        let lateProgressTransportID = UUID()
        lateProgressDeadline.beginSession(transportAttemptID: lateProgressTransportID)
        let lateProgressStarted = AsyncTestSignal()
        let releaseLateProgressOperation = AsyncTestSignal()
        let lateProgressRun = Task { @MainActor in
            await lateProgressDeadline.run(deadline: .seconds(2), operation: {
                await lateProgressStarted.signal()
                await releaseLateProgressOperation.wait()
                return false
            }, onTimeout: {}, onProgress: { _ in })
        }
        await lateProgressStarted.wait()
        lateProgressDeadline.recordFailure(URLError(.networkConnectionLost))
        lateProgressDeadline.recordPostAckCompletion(postAckReached: true,
            relayRefreshConfirmed: false, generationMatches: true,
            profileMatches: true, relayContextMatches: false)
        lateProgressDeadline.observe(.postAckDrainFinished(.failed), transportAttemptID: lateProgressTransportID)
        await releaseLateProgressOperation.signal()
        let lateProgressFailure = await lateProgressRun.value
        XCTAssertEqual(lateProgressFailure.failureClass,
                       .urlSession(code: URLError.networkConnectionLost.rawValue),
                       "A queued post-ACK progress event must not erase the caught transport cause.")
        XCTAssertEqual(lateProgressFailure.postAckDrainTransition, .failed)

        let journalURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightPostAckDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: journalURL) }
        let journal = NativeClientDiagnosticJournal(fileURL: journalURL)
        let terminalEvents = [
            NativeRelayLifecycle.foregroundTerminalDiagnosticEvents(progress: failed,
                confirmed: false, generationMatches: false, profileMatches: true,
                relayContextMatches: false),
            NativeRelayLifecycle.foregroundTerminalDiagnosticEvents(progress: confirmed,
                confirmed: true, generationMatches: true, profileMatches: true,
                relayContextMatches: true),
            NativeRelayLifecycle.foregroundTerminalDiagnosticEvents(progress: timeoutDeadline.progress,
                confirmed: false, timedOut: true, generationMatches: false, profileMatches: true,
                relayContextMatches: false),
            NativeRelayLifecycle.foregroundTerminalDiagnosticEvents(progress: cancelled,
                confirmed: false, generationMatches: true, profileMatches: true,
                relayContextMatches: false),
            NativeRelayLifecycle.foregroundTerminalDiagnosticEvents(progress: lateProgressFailure,
                confirmed: false, generationMatches: true, profileMatches: true,
                relayContextMatches: false)
        ].flatMap { $0 }
        journal.record(terminalEvents)
        let restored = NativeClientDiagnosticJournal(fileURL: journalURL)
        XCTAssertEqual(restored.persistenceStatus, .saved)
        XCTAssertTrue(restored.shareText.contains("phase=foregroundGenerationValidation transition=cancelled cause=foreground_generation_invalidated"))
        XCTAssertTrue(restored.shareText.contains("phase=foregroundProfileValidation transition=completed"))
        XCTAssertTrue(restored.shareText.contains("phase=foregroundContextValidation transition=unresolved cause=foreground_relay_context_unconfirmed"))
        XCTAssertTrue(restored.shareText.contains("phase=foregroundCompletion transition=cancelled cause=none_observed terminal_reason=generation_invalidated"))
        XCTAssertTrue(restored.shareText.contains("post_ack_boundary=post_ack_relay_refresh_returned"))
        XCTAssertTrue(restored.shareText.contains("post_ack_drain=failed"))
        XCTAssertTrue(restored.shareText.contains("phase=foregroundCompletion transition=completed cause=none_observed terminal_reason=foreground_confirmed"))
        let completion = try XCTUnwrap(restored.events.first { $0.phase == .foregroundCompletion })
        XCTAssertEqual(completion.postAckBoundary, .relayRefreshReturned)
        XCTAssertEqual(completion.postAckDrainTransition, .failed)
        XCTAssertTrue(restored.shareText.contains("post_ack_boundary=foreground_confirmed"))
        XCTAssertTrue(restored.shareText.contains("post_ack_drain=timedOut"))
        XCTAssertTrue(restored.shareText.contains("terminal_reason=foreground_deadline"))
        XCTAssertTrue(restored.shareText.contains("phase=foregroundCompletion transition=cancelled cause=cancelled terminal_reason=cancelled"))
        XCTAssertTrue(restored.shareText.contains("cause=url_session_error_code_\(URLError.networkConnectionLost.rawValue)"))
        let successCompletion = try XCTUnwrap(restored.events.first {
            $0.phase == .foregroundCompletion && $0.transition == .completed
        })
        XCTAssertEqual(successCompletion.postAckBoundary, .foregroundConfirmed)
        XCTAssertEqual(successCompletion.postAckDrainTransition, .completed)
        let timeoutCompletion = try XCTUnwrap(restored.events.first {
            $0.phase == .foregroundCompletion && $0.transition == .timedOut
        })
        XCTAssertEqual(timeoutCompletion.postAckBoundary, .nativeCursorAcknowledged)
        XCTAssertEqual(timeoutCompletion.postAckDrainTransition, .timedOut)
        XCTAssertTrue(restored.shareText.contains("attempt_id=\(failed.attemptID!.uuidString.lowercased())"))
        XCTAssertTrue(restored.shareText.contains("transport_attempt_id=\(transportAttemptID.uuidString.lowercased())"))
        XCTAssertFalse(restored.shareText.contains("answer="))
        XCTAssertFalse(restored.shareText.contains("token="))
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
        deadline.observe(.postAckDrainBegan, transportAttemptID: firstTransportID)
        deadline.observe(.postAckDrainFinished(.completed), transportAttemptID: firstTransportID)
        deadline.recordFailure(URLError(.networkConnectionLost))

        let secondTransportID = UUID()
        deadline.beginTransportAttempt(secondTransportID)
        XCTAssertEqual(deadline.progress.transportAttemptID, secondTransportID)
        XCTAssertNil(deadline.progress.lastConfirmedStage)
        XCTAssertFalse(deadline.progress.webSocketOpenObserved)
        XCTAssertFalse(deadline.progress.nativeSyncReplayRequested)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.id, firstTransportID)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.lastConfirmedStage, .nativeSyncAcknowledged)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.lastCompletedPostAckBoundary, .coreDrainCompleted)
        XCTAssertEqual(deadline.progress.previousTransportAttempt?.postAckDrainTransition, .completed)
        XCTAssertEqual(deadline.progress.lastCompletedPostAckBoundary, .none,
                       "A replacement transport must not inherit a historical cursor checkpoint as its own.")
        XCTAssertNil(deadline.progress.postAckDrainTransition)
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
        XCTAssertTrue(diagnostic.shareText.contains("last_completed_post_ack_boundary=none_observed"))
        XCTAssertTrue(diagnostic.shareText.contains("previous_last_completed_post_ack_boundary=post_ack_core_drain_completed"))
        XCTAssertTrue(diagnostic.shareText.contains("previous_post_ack_drain=completed"))
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

    func testReceivedInvitationContinuesAutomaticApprovalPolling() async throws {
        let namespace = "Harklight.received-invitation-approval-poll." + UUID().uuidString
        let certificateURL = try XCTUnwrap(Bundle(for: NativeGuidedTLSTests.self)
            .url(forResource: "guided-local-tls", withExtension: "pem"))
        let caPEM = try String(contentsOf: certificateURL, encoding: .utf8)
        let caDER = try XCTUnwrap(NativeEnrollmentSettings.certificateDER(from: caPEM))
        let caSHA256 = SHA256.hash(data: caDER).map { String(format: "%02x", $0) }.joined()
        let payload: [String: Any] = [
            "v": 1,
            "person_id": "invited-person",
            "server_name": "relay.example.test",
            "enrollment_url": "https://relay.example.test:18444/enroll",
            "relay_url": "wss://relay.example.test:18443/relay",
            "ca_pem": caPEM,
            "ca_sha256": caSHA256,
            "invite_token": String(repeating: "1", count: 64),
            "expires_at": Int64(Date().timeIntervalSince1970 * 1000) + 1_800_000
        ]
        let invitation = try NativeJoinInvitation.decodePayload(JSONSerialization.data(withJSONObject: payload))
        let invitationData = try JSONEncoder().encode(invitation)
        let encodedInvitation = invitationData.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let invitationURL = try XCTUnwrap(URL(string: "harklight://join#\(encodedInvitation)"))

        let transport = InvitationApprovalPollingTransport()
        let store = NativeGuidedJoinStore(namespace: namespace, transport: transport)
        transport.store = store
        defer {
            if let attempt = try? store.loadAttempt() {
                SecItemDelete([kSecClass as String: kSecClassCertificate,
                               kSecAttrLabel as String: attempt.identityLabel] as CFDictionary)
                let keyTag = String(attempt.identityLabel.dropLast(".certificate".count))
                SecItemDelete([kSecClass as String: kSecClassKey,
                               kSecAttrApplicationTag as String: Data(keyTag.utf8)] as CFDictionary)
            }
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: namespace] as CFDictionary)
        }

        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "Test device")
        var connectedRecord: NativeEnrollmentRecord?
        flow.connectApproved = { record in
            connectedRecord = record
            return true
        }

        await flow.receive(invitationURL)
        XCTAssertEqual(flow.screen, .confirmation,
                       "Receiving a valid link reaches the ordinary, deliberate Join confirmation.")
        await flow.join()
        XCTAssertEqual(flow.screen, .pending)
        let originalAttempt = try XCTUnwrap(store.loadAttempt())

        XCTAssertFalse(flow.shouldAutomaticallyRetry(foregroundOutcome: .timedOut),
                       "The timeout stop still applies after receiving an invitation.")
        let retriedTimedOutAttempt = await flow.retryAutomaticallyIfNeeded(foregroundOutcome: .timedOut)
        XCTAssertFalse(retriedTimedOutAttempt)
        XCTAssertEqual(transport.approvalCheckCount, 0,
                       "A timed-out foreground attempt still waits for the explicit Retry action.")
        XCTAssertTrue(flow.shouldAutomaticallyRetry(foregroundOutcome: .incomplete),
                      "Receiving an invitation must not disable non-timed-out approval polling.")
        let didPoll = await flow.retryAutomaticallyIfNeeded(foregroundOutcome: .incomplete)

        XCTAssertTrue(didPoll)
        XCTAssertEqual(transport.joinSubmissionCount, 1,
                       "Approval polling must not create a second Join request.")
        XCTAssertEqual(transport.approvalCheckCount, 1,
                       "The actual automatic helper must check the pending request after invitation receipt.")
        XCTAssertEqual(flow.screen, .connected,
                       "The ordinary invitation flow observes and completes owner approval.")
        XCTAssertEqual(flow.attempt?.id, originalAttempt.id)
        XCTAssertEqual(flow.attempt?.deviceID, originalAttempt.deviceID)
        XCTAssertEqual(connectedRecord?.personID, invitation.personID)
        XCTAssertEqual(connectedRecord?.deviceID, originalAttempt.deviceID)
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
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)

        let diagnosticURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }
        let diagnosticJournal = NativeClientDiagnosticJournal(fileURL: diagnosticURL)
        let lifecycle = NativeRelayLifecycle()
        try await lifecycle.activate(store: store, context: context, relayURL: relayURL,
                                     clientIdentity: installation.value, trustedRootDER: server.rootDER,
                                     diagnostics: diagnosticJournal)
        var progressUpdates: [NativeForegroundConnectProgress] = []
        var operationSnapshots: [NativeForegroundOperationSnapshot] = []
        let result = await lifecycle.confirmForegroundProgress(for: context, deadline: .seconds(3)) {
            progressUpdates.append($0)
            operationSnapshots.append(lifecycle.foregroundOperationDiagnostics(for: context))
        }

        XCTAssertEqual(result.outcome, .timedOut)
        XCTAssertEqual(result.headline, "Connection not confirmed",
                       "An actual stalled relay must keep the existing connection warning.")
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
        let restoredAfterTimeout = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredSnapshot = try restoredAfterTimeout.snapshot(context: context)
        XCTAssertEqual(restoredSnapshot.cursor, 1,
                       "The stalled connection must preserve the approved profile's replay cursor.")
        XCTAssertEqual(restoredSnapshot.outbox.first?.operationID, originalOperation.operationID,
                       "The stalled connection must preserve its exact queued operation.")
        XCTAssertEqual(try restoredAfterTimeout.conversationSnapshot(context: context)
            .threads[requestKey]?.drafts[1]?.text, ExactText("Keep this draft"),
                       "The stalled connection must preserve the saved conversation draft.")
        XCTAssertEqual(try NativeInstallationIdentityStore(namespace: namespace).loadOrCreate().deviceID,
                       installation.deviceID, "The approved device identity remains available after timeout.")
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertEqual(try store.snapshot(context: context).outbox.count, 1)
        XCTAssertEqual(try store.conversationSnapshot(context: context).threads[requestKey]?.drafts[1]?.text,
                       ExactText("Keep this draft"))
        let timeoutEvent = try XCTUnwrap(diagnosticJournal.events.first {
            $0.phase == .approvedConnection && $0.transition == .timedOut &&
                $0.causeCode == "foreground_deadline"
        }, "A real stalled local connection must leave a retrievable timeout record.")
        XCTAssertEqual(timeoutEvent.transportAttemptID, result.transportAttemptID,
                       "The foreground timeout and actual socket attempt must remain correlated.")
        let persistedDiagnostics = NativeClientDiagnosticJournal(fileURL: diagnosticURL)
        XCTAssertTrue(persistedDiagnostics.shareText.contains("phase=approvedConnection"))
        XCTAssertTrue(persistedDiagnostics.shareText.contains("transition=timedOut"))
        let transportAttemptID = try XCTUnwrap(timeoutEvent.transportAttemptID)
        XCTAssertTrue(persistedDiagnostics.shareText.contains("transport_attempt_id=\(transportAttemptID.uuidString.lowercased())"))
        XCTAssertTrue(persistedDiagnostics.shareText.contains("operation_id=\(originalOperation.operationID.uuidString.lowercased())") == false,
                      "An operation not yet sent must not be mislabeled as a transport attempt.")
        XCTAssertEqual(try store.snapshot(context: context).outbox.first?.operationID,
                       originalOperation.operationID,
                       "Diagnostics must not change or resubmit the original queued operation.")
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

    func testAcceptedOriginalOperationReplayIsJoinedToItsSavedBinding() async throws {
        let (context, store, session) = try makeU2ReplayFixture()
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("answer-request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        let submission = try XCTUnwrap(store.snapshot(context: context).outbox.first)
        session.result = .accepted(operationID: receipt.opID, terminalSequence: 2)
        session.replayFrames = [
            [u2Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             u2Data(#"{"v":1,"type":"resynced","seq":1}"#)],
            [u2Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             u2Data(#"{"v":1,"type":"lifecycle","seq":2,"sender_id":"sender","message_id":"answer-request","origin":"other-installation","state":"answered","at":2}"#),
             u2Data(#"{"v":1,"type":"resynced","seq":2}"#)]
        ]
        let events = NativeDiagnosticEventCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: { events.append($0) })

        _ = try await core.resyncAndDrainOutbox()

        let replay = events.events.filter {
            $0.phase == .ordinaryReplay && $0.operationID == submission.operationID
        }
        XCTAssertTrue(replay.contains {
            $0.transition == .began && $0.receiptState == .acceptedAwaitingReplay &&
                $0.requestTag != nil && $0.requestRevision == 1
        })
        XCTAssertTrue(replay.contains {
            $0.transition == .completed && $0.receiptState == .terminal &&
                $0.requestTag != nil && $0.requestRevision == 1
        })
        XCTAssertEqual(session.sent.first?.1, receipt.opID,
                       "Replay must keep the accepted operation's original UUID.")
        XCTAssertEqual(session.acknowledgements.count, 1,
                       "The checkpoint ACK is separate; only terminal sequence 2 uses ordinary ACK.")
        XCTAssertEqual(try JSONValue.parse(try XCTUnwrap(session.acknowledgements.first))
            .uniqueValue(named: "seq"), .number(JSONNumber(lexeme: "2")))
        XCTAssertEqual(try store.snapshot(context: context).cursor, 2)
        XCTAssertEqual(try store.snapshot(context: context).remoteStates[key]?.state, .answered)

        let diagnosticURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightAcceptedReplayDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }
        let journal = NativeClientDiagnosticJournal(fileURL: diagnosticURL)
        journal.record(events.events)
        let restored = NativeClientDiagnosticJournal(fileURL: diagnosticURL)
        XCTAssertTrue(restored.shareText.contains("operation_id=\(submission.operationID.uuidString.lowercased())"))
        XCTAssertTrue(restored.shareText.contains("request_revision=1"))
        XCTAssertTrue(restored.shareText.contains("receipt_state=acceptedAwaitingReplay"))
        XCTAssertTrue(restored.shareText.contains("receipt_state=terminal"))
        XCTAssertFalse(restored.shareText.contains("answer="))
    }

    func testAcceptedOperationReplayFailureKeepsExactReceiptAndCauseRetrievable() async throws {
        let (context, store, session) = try makeU2ReplayFixture()
        let key = RequestKey(accountScope: context.identity.personID,
                             senderID: ExactText("sender"), messageID: ExactText("answer-request"))
        let payload = try JSONValue.parse(Data(#"{"title":"Prompt","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"yes","label":"Yes","kind":"value","value":{"ok":true}}]}}"#.utf8))
        _ = try store.apply(RelayEvent(sequence: 1,
            body: .delivery(StoredRequest(key: key, originalPayload: payload), .message),
            conversation: RelayConversationMetadata(revision: 1, sessionHandle: ExactText("session"))),
            context: context)
        let port = AttentionDomainPort(store: store)
        let selector = try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first?.selector)
        let receipt = try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityValue(action: ExactText("yes"))]))
        session.result = .accepted(operationID: receipt.opID, terminalSequence: 2)
        session.replayFrames = [
            [u2Data(#"{"v":1,"type":"ok","ref":"native-sync"}"#),
             u2Data(#"{"v":1,"type":"resynced","seq":1}"#)]
        ]
        session.resyncFailureOnCall = 2
        let events = NativeDiagnosticEventCollector()
        let core = try NativeRelayCore(store: store, context: context, session: session,
                                       onDiagnostic: { events.append($0) })

        do {
            _ = try await core.resyncAndDrainOutbox()
            XCTFail("The follow-on replay failure must remain visible to its accepted operation.")
        } catch InstallationTransportError.unexpectedServerFrame {}

        let submission = try XCTUnwrap(store.snapshot(context: context).intents[receipt.intentID])
        let replayFailure = events.events.first {
            $0.phase == .ordinaryReplay && $0.transition == .failed &&
                $0.operationID == submission.operationID
        }
        XCTAssertEqual(replayFailure?.causeCode, "unexpected_relay_frame")
        XCTAssertEqual(replayFailure?.requestRevision, 1)
        XCTAssertNotNil(replayFailure?.requestTag)
        XCTAssertEqual(replayFailure?.receiptState, .acceptedAwaitingReplay)
        XCTAssertEqual(session.sent.first?.1, receipt.opID,
                       "A retry must stay bound to the accepted operation, never a replacement answer.")
        XCTAssertEqual(session.acknowledgements.count, 0,
                       "The checkpoint ACK is separate, and failed terminal replay must not ordinary-ACK.")
        XCTAssertEqual(try store.snapshot(context: context).cursor, 1)
        XCTAssertTrue(try store.snapshot(context: context).outbox.isEmpty,
                      "The accepted operation is not silently requeued as a new answer.")

        let diagnosticURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarklightReplayFailureDiagnostics-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: diagnosticURL) }
        let journal = NativeClientDiagnosticJournal(fileURL: diagnosticURL)
        journal.record(events.events)
        let restored = NativeClientDiagnosticJournal(fileURL: diagnosticURL)
        XCTAssertTrue(restored.shareText.contains("cause=unexpected_relay_frame"))
        XCTAssertTrue(restored.shareText.contains("operation_id=\(submission.operationID.uuidString.lowercased())"))
        XCTAssertTrue(restored.shareText.contains("request_revision=1"))
        XCTAssertTrue(restored.shareText.contains("receipt_state=acceptedAwaitingReplay"))
        XCTAssertFalse(restored.shareText.contains("answer="))
    }

    private func makeU2ReplayFixture() throws -> (ProfileContext, AttentionDomainStore, U2ReplaySession) {
        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("relay.example"),
                                       personID: ExactText("person-A"),
                                       deviceID: ExactText("installation-A"))
        let context = ProfileContext(identity: identity, transportMode: .relay)
        return (context,
                try AttentionDomainStore(context: context, persistence: MemoryAttentionStatePersistence()),
                U2ReplaySession(identity))
    }

    private func u2Data(_ text: String) -> Data { Data((text + "\n").utf8) }

    private final class U2ReplaySession: AuthenticatedInboxPagingSession, @unchecked Sendable {
        let authenticatedIdentity: ProfileIdentity
        var acknowledgements: [Data] = []
        var sent: [(Data, UUID)] = []
        var result: OriginalOperationResult = .unresolved
        var replayFrames: [[Data]] = []
        var resyncFailureOnCall: Int?

        private var requests: [Data] = []

        init(_ identity: ProfileIdentity) { authenticatedIdentity = identity }

        func resync(_ request: Data,
                    consume: @Sendable (Data) async throws -> Void) async throws {
            requests.append(request)
            if resyncFailureOnCall == requests.count {
                throw InstallationTransportError.unexpectedServerFrame
            }
            let selected = replayFrames.isEmpty ? [] : replayFrames.removeFirst()
            for frame in selected {
                try await consume(frame)
            }
        }

        func acknowledge(_ request: Data) async throws {
            acknowledgements.append(request)
        }

        func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
            sent.append((frame, operationID))
            return result
        }
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

@MainActor
private final class InvitationApprovalPollingTransport: NativeJoinTransport {
    weak var store: NativeGuidedJoinStore?
    private(set) var joinSubmissionCount = 0
    private(set) var approvalCheckCount = 0

    func request(_ url: URL, method: String, body: Data?, rootDER: Data) async throws -> NativeJoinResponse {
        switch (url.path, method) {
        case ("/enroll", "GET"):
            return try reply(["state": "reachable"])
        case ("/enroll", "POST"):
            joinSubmissionCount += 1
            let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 600_000
            return try reply(["state": "pending", "approval_code": "ABCDEF2345",
                              "expires_at": deadline, "status_expires_at": deadline + 86_400_000])
        case ("/enroll/status", "POST"):
            approvalCheckCount += 1
            guard let attempt = try store?.loadAttempt() else { throw NativeJoinError.unavailable }
            let fields: [String: Any] = ["state": "approved", "person_id": attempt.invitation.personID,
                                         "device_id": attempt.deviceID]
            return try reply(fields)
        default:
            throw NativeJoinError.unavailable
        }
    }

    private func reply(_ fields: [String: Any]) throws -> NativeJoinResponse {
        NativeJoinResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: fields))
    }
}

@MainActor
private final class ArchiveRemovalTransport: NativeJoinTransport {
    var peopleByDevice: [String: String] = [:]

    func request(_ url: URL, method: String, body: Data?, rootDER: Data) async throws -> NativeJoinResponse {
        NativeJoinResponse(statusCode: 200, data: Data("{\"state\":\"reachable\"}".utf8))
    }

    func remove(_ url: URL, body: Data, rootDER: Data, identity: SecIdentity) async throws -> NativeJoinResponse {
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        let device = fields["expected_device_id"] ?? ""
        let payload: [String: Any] = ["state": "removed", "person_id": peopleByDevice[device] ?? "",
                                      "device_id": device, "enrollment_revision": 2]
        return NativeJoinResponse(statusCode: 200, data: try JSONSerialization.data(withJSONObject: payload))
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

/// A local TLS WebSocket relay. Each text message from the app is passed to
/// `reply`, and the returned frames are sent back in order.
private final class LocalRelayWebSocket: @unchecked Sendable {
    let rootDER: Data
    private let listener: NWListener
    private let queue = DispatchQueue(label: "Harklight.local-relay-websocket")
    private let reply: @Sendable (String) -> [String]
    // All connection ownership is serialized on queue, including close().
    private var connections: [NWConnection] = []

    init(expectedDevice: String, reply: @escaping @Sendable (String) -> [String]) throws {
        self.reply = reply
        let (tls, root) = try LocalEnrollmentTLS.fixtureTLS(expectedDevice: expectedDevice, queue: queue)
        rootDER = root
        let webSocket = NWProtocolWebSocket.Options()
        webSocket.autoReplyPing = true
        webSocket.setClientRequestHandler(queue) { _, _ in
            NWProtocolWebSocket.Response(status: .accept, subprotocol: "attention-relay/1", additionalHeaders: nil)
        }
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.defaultProtocolStack.applicationProtocols.insert(webSocket, at: 0)
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
                connection.start(queue: queue)
                receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, error == nil else { connection.cancel(); return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .text, let data, let text = String(data: data, encoding: .utf8) {
                for frame in reply(text) {
                    let context = NWConnection.ContentContext(
                        identifier: "relay-frame", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
                    connection.send(content: Data(frame.utf8), contentContext: context, isComplete: true,
                                    completion: .idempotent)
                }
            }
            receive(connection)
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

private final class ConversationFrameCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [Data] = []
    private var queuedHighWater = 0
    var maxQueued: Int {
        lock.lock(); defer { lock.unlock() }
        return queuedHighWater
    }
    var types: [String?] {
        lock.lock(); defer { lock.unlock() }
        return frames.map { try? JSONValue.parse($0).uniqueValue(named: "type")?.stringValue?.rawValue }
    }
    var conversationSeqs: [Int] {
        lock.lock(); defer { lock.unlock() }
        return frames.compactMap { frame in
            guard let value = try? JSONValue.parse(frame),
                  value.uniqueValue(named: "type")?.stringValue?.rawValue == "conversation" else { return nil }
            return value.uniqueValue(named: "conversation_seq")?.integerValue
        }
    }

    func append(_ frame: Data) {
        lock.lock(); frames.append(frame); lock.unlock()
    }

    func noteQueued(_ count: Int) {
        lock.lock(); queuedHighWater = max(queuedHighWater, count); lock.unlock()
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

private final class ForegroundProgressRelaySession: AuthenticatedInboxPagingSession, @unchecked Sendable {
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

/// Feeds exact ordinary v1 relay frames through NativeRelayCore's real decoder,
/// replay barrier and ACK path without making a network connection.
private final class OrdinaryOrderingRelaySession: AuthenticatedInboxPagingSession, @unchecked Sendable {
    let authenticatedIdentity: ProfileIdentity
    private let lock = NSLock()
    private var replayCount = 0
    private var ackValues: [UInt64] = []
    private var sentOperation: (UUID, Data)?

    init(identity: ProfileIdentity) { authenticatedIdentity = identity }

    func resync(_ request: Data, consume: @Sendable (Data) async throws -> Void) async throws {
        for frame in nextReplayFrames() {
            try await consume(Data((frame + "\n").utf8))
        }
    }

    func acknowledge(_ request: Data) async throws {
        let value = try JSONValue.parse(request)
        guard value.uniqueValue(named: "type")?.stringValue == ExactText("ack"),
              let raw = value.uniqueValue(named: "seq"),
              case let .number(value) = raw,
              let sequence = UInt64(value.lexeme) else {
            throw NativeRelayCoreError.invalidReplay
        }
        recordAcknowledgement(sequence)
    }

    func sendOriginalOperation(_ frame: Data, operationID: UUID) async throws -> OriginalOperationResult {
        recordSentOperation(operationID, frame: frame)
        return .accepted(operationID: operationID, terminalSequence: 4)
    }

    func acknowledgedSequences() -> [UInt64] {
        lock.lock(); defer { lock.unlock() }
        return ackValues
    }

    func sentOriginalOperation() -> (operationID: UUID, frame: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard let sentOperation else { return nil }
        return (sentOperation.0, sentOperation.1)
    }

    private func recordAcknowledgement(_ sequence: UInt64) {
        lock.lock(); defer { lock.unlock() }
        ackValues.append(sequence)
    }

    private func recordSentOperation(_ operationID: UUID, frame: Data) {
        lock.lock(); defer { lock.unlock() }
        sentOperation = (operationID, frame)
    }

    private func nextReplayFrames() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let current = replayCount
        replayCount += 1
        switch current {
        case 0:
            return [
                #"{"v":1,"type":"ok","ref":"native-sync"}"#,
                #"{"v":1,"type":"delivery","seq":1,"sender_id":"sender","message_id":"notice","origin":"other-installation","as":"message","message":{"title":"Build complete","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"seen","label":"Seen","kind":"value","value":{"acknowledgment":"seen"}}]}}}"#,
                #"{"v":1,"type":"delivery","seq":2,"sender_id":"sender","message_id":"structured","origin":"other-installation","as":"message","message":{"title":"Approve request","answer_ui":{"schema":"attention-client.actions/1","actions":[{"id":"approve","label":"Approve","kind":"value","value":"approved"}]}}}"#,
                #"{"v":1,"type":"delivery","seq":3,"sender_id":"sender","message_id":"legacy","origin":"other-installation","as":"message","message":{"title":"Legacy request"}}"#,
                #"{"v":1,"type":"resynced","seq":3}"#
            ]
        case 1:
            return [
                #"{"v":1,"type":"ok","ref":"native-sync"}"#,
                #"{"v":1,"type":"resynced","seq":3}"#
            ]
        default:
            return [
                #"{"v":1,"type":"ok","ref":"native-sync"}"#,
                #"{"v":1,"type":"lifecycle","seq":4,"sender_id":"sender","message_id":"notice","origin":"other-installation","state":"answered","by":"agent_answer","request_revision":1,"event_id":"terminal-4","author":"agent"}"#,
                #"{"v":1,"type":"resynced","seq":4}"#
            ]
        }
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
