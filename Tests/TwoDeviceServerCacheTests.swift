import AttentionDomain
import Foundation
import HarklightNativeRelay
import XCTest
@testable import Harklight

/// Explicitly selected phases on two separately enrolled simulators. Every
/// request and response comes from the same published isolated server.
@MainActor
final class TwoDeviceServerCacheTests: XCTestCase {
    private let namespace = "co.clicketyclacks.Harklight.isolated-network-diagnosis"
    private struct Manifest: Decodable {
        let senderID: String
        let seenMessageID: String
        let replyMessageID: String
        let expectedRequestCount: Int
        let replyText: String
    }

    func testRequestDeviceBApproval() async throws {
        _ = try manifest()
        var phase = "invitation_handoff"
        do {
            let file = try documents().appendingPathComponent("two-device-invitation.txt")
            print("TWO_DEVICE_INVITATION_RECEIVER " + file.path)
            let deadline = ContinuousClock.now.advanced(by: .seconds(180))
            while !FileManager.default.fileExists(atPath: file.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(250))
            }
            guard FileManager.default.fileExists(atPath: file.path) else {
                XCTFail("Private invitation did not arrive within this request window.")
                return
            }
            defer { try? FileManager.default.removeItem(at: file) }
            phase = "invitation_decode"
            let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: text) else { throw NativeJoinInvitationError.invalid }
            let invitation = try NativeJoinInvitation.decode(url)
            let join = NativeGuidedJoinStore(namespace: namespace)
            phase = "destination_tls"
            try await join.verifyDestination(invitation)
            print("TWO_DEVICE_DESTINATION_VERIFIED")
            phase = "prepare"
            _ = try join.prepare(invitation, deviceLabel: "Isolated second client")
            phase = "submit"
            let attempt = try await join.submit()
            guard attempt.phase == .pending, let code = attempt.approvalCode,
                  let expires = attempt.approvalExpiresAt else {
                print("TWO_DEVICE_REQUEST_PHASE " + attempt.phase.rawValue)
                XCTFail("Native enrollment did not return a pending approval.")
                return
            }
            let pending = try documents().appendingPathComponent("two-device-pending.json")
            let data = try JSONSerialization.data(withJSONObject: [
                "approval_code": code, "device_id": attempt.deviceID, "expires_at": expires
            ], options: .sortedKeys)
            try data.write(to: pending, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pending.path)
            print("TWO_DEVICE_PENDING_APPROVAL " + pending.path)
        } catch {
            reportFailure(error, phase: phase)
        }
    }


    func testDeviceACachesOpenRequestsAndQueuesUnsentReply() async throws {
        let config = try manifest()
        do {
            let material = try await approvedMaterial()
            let (repository, cache) = try storage(material)
            let lifecycle = NativeRelayLifecycle()
            try await connect(lifecycle, material, repository, cache, config)
            let port = AttentionDomainPort(store: repository)
            let reply = key(config.replyMessageID, config, material)
            let seen = key(config.seenMessageID, config, material)
            XCTAssertEqual(try presented(port, reply).lifecycleStatus, .open)
            XCTAssertEqual(try presented(port, seen).lifecycleStatus, .open)
            let receipt = try queueReply(port, reply, text: "Unsent answer on the first device")
            let queueID = try documents().appendingPathComponent("two-device-queued-id.txt")
            try receipt.intentID.uuidString.write(to: queueID, atomically: true, encoding: .utf8)
            let snapshot = ServerStateCacheSnapshot.make(identity: material.context.identity,
                from: try repository.snapshot(context: material.context),
                conversations: try repository.conversationSnapshot(context: material.context))
            try await cache.save(snapshot)
            await lifecycle.deactivate()
            print("TWO_DEVICE_A_CACHE_AND_UNSENT_QUEUE_READY")
        } catch { reportFailure(error, phase: "a_prepare") }
    }

    func testRetainDeviceBApprovalForNormalAppLaunch() async throws {
        _ = try manifest()
        do {
            let join = NativeGuidedJoinStore(namespace: namespace)
            let attempt = try await join.checkApproval()
            guard attempt.phase == .approved, let record = try join.approvedRecord(),
                  let person = record.personID else { throw NativeEnrollmentError.approvalPending }
            try NativeEnrollmentStore().retainApprovedGuided(record,
                expectedPersonID: person, expectedDeviceID: attempt.deviceID)
            print("TWO_DEVICE_B_ACTUAL_APPROVAL_RETAINED_FOR_APP")
        } catch { reportFailure(error, phase: "b_approval_for_app") }
    }

    func testDeviceARestartAdoptsOtherDevicesAnswersWithoutSendingItsQueue() async throws {
        let config = try manifest()
        do {
            let material = try await approvedMaterial()
            let (repository, cache) = try storage(material)
            let loaded = try await cache.load()
            let cached = try XCTUnwrap(loaded)
            try repository.restoreCachedServerState(cached.attentionDomainState(for: material.context.identity),
                                                    context: material.context)
            let port = AttentionDomainPort(store: repository)
            let reply = key(config.replyMessageID, config, material)
            let seen = key(config.seenMessageID, config, material)
            XCTAssertEqual(try presented(port, reply).lifecycleStatus, .open,
                           "The first device must start with the earlier server cache.")
            let idText = try String(contentsOf: documents().appendingPathComponent("two-device-queued-id.txt"), encoding: .utf8)
            let id = try XCTUnwrap(UUID(uuidString: idText))
            XCTAssertNotNil(try repository.lookupIntent(id, context: material.context))
            let lifecycle = NativeRelayLifecycle()
            try await connect(lifecycle, material, repository, cache, config)
            XCTAssertEqual(try presented(port, seen).accountAnswerOutcome, .seen)
            XCTAssertEqual(try presented(port, seen).informationalSeenStatus, .confirmed)
            XCTAssertEqual(try presented(port, reply).accountAnswerOutcome, .reply(ExactText(config.replyText)))
            XCTAssertNil(try presented(port, reply).submittedAnswer)
            XCTAssertTrue(try repository.snapshot(context: material.context).outbox.isEmpty)
            // A pending local request cannot override the account terminal.
            // Only the preparation boundary is exercised; no send is invoked.
            XCTAssertThrowsError(try repository.queueOriginalOperationForUserTap(id, context: material.context))
            await lifecycle.deactivate()
            print("TWO_DEVICE_A_ADOPTED_SERVER_TERMINALS_QUEUE_NOT_SENT")
        } catch { reportFailure(error, phase: "a_restore") }
    }

    private enum ProbeFailure: Error { case unconfirmed, incomplete }

    private func storage(_ material: NativeInstallationMaterial) throws -> (ClientRepository, FileServerStateCache) {
        let root = try documents().appendingPathComponent("two-device-cache", isDirectory: true)
        let repository = try ClientRepository(context: material.context,
            persistence: FilePendingActionPersistence(directoryURL: root.appendingPathComponent("queue")))
        let cache = FileServerStateCache(identity: material.context.identity,
            fileURL: root.appendingPathComponent("server.json"))
        return (repository, cache)
    }

    private func connect(_ lifecycle: NativeRelayLifecycle, _ material: NativeInstallationMaterial,
                         _ repository: ClientRepository, _ cache: FileServerStateCache,
                         _ config: Manifest) async throws {
        let journal = NativeClientDiagnosticJournal(fileURL: nil)
        try await lifecycle.activate(store: repository, context: material.context,
            relayURL: material.relayURL, clientIdentity: material.keychainIdentity,
            trustedRootDER: material.trustedRootDER, diagnostics: journal, serverStateCache: cache)
        let progress = await lifecycle.confirmForegroundProgress(for: material.context)
        guard progress.outcome == .confirmed else {
            await lifecycle.deactivate()
            throw ProbeFailure.unconfirmed
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        while try repository.snapshot(context: material.context).requests.count < config.expectedRequestCount,
              ContinuousClock.now < deadline {
            // The view loader may exhaust the pages concurrently. False is not
            // an error if the complete server checkpoint has already arrived.
            _ = await lifecycle.fetchNextInboxPage()
            await Task.yield()
        }
        let snapshot = try repository.snapshot(context: material.context)
        guard snapshot.requests.count == config.expectedRequestCount,
              lifecycle.hasConfirmedServerSnapshot(for: material.context) else {
            await lifecycle.deactivate()
            throw ProbeFailure.incomplete
        }
        print("TWO_DEVICE_CONFIRMED count=\(snapshot.requests.count)")
    }

    private func queueReply(_ port: AttentionDomainPort, _ key: RequestKey, text: String) throws -> IntentReceipt {
        let selector = try XCTUnwrap(try presented(port, key).selector)
        return try port.submit(SubmitIntent(context: port.context, selector: selector,
            intentID: UUID(), inputs: [.compatibilityText(action: ExactText("reply"), text: ExactText(text))]))
    }

    private func presented(_ port: AttentionDomainPort, _ key: RequestKey) throws -> PresentedRequest {
        try XCTUnwrap(port.inspect(context: port.context, request: key).requests.first)
    }

    private func key(_ message: String, _ config: Manifest, _ material: NativeInstallationMaterial) -> RequestKey {
        RequestKey(accountScope: material.context.identity.personID,
            senderID: ExactText(config.senderID), messageID: ExactText(message))
    }

    private func approvedMaterial() async throws -> NativeInstallationMaterial {
        let join = NativeGuidedJoinStore(namespace: namespace)
        let attempt = try await join.checkApproval()
        guard attempt.phase == .approved, let record = try join.approvedRecord() else {
            throw NativeEnrollmentError.approvalPending
        }
        return try NativeEnrollmentStore(service: namespace).material(from: record)
    }

    private func documents() throws -> URL {
        try XCTUnwrap(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first)
    }

    private func manifest() throws -> Manifest {
        guard let file = Bundle(for: Self.self).url(forResource: "two-device-server-cache", withExtension: "json") else {
            throw XCTSkip("Requires two accepted disposable devices on one isolated published server.")
        }
        return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
    }

    private func reportFailure(_ error: any Error, phase: String) {
        print("TWO_DEVICE_FAILURE phase=\(phase) type=\(String(reflecting: type(of: error))) code=\((error as NSError).code)")
        XCTFail("Isolated two-device phase failed: \(phase)")
    }
}
