import CryptoKit
import Foundation
import HarklightNativeRelay
import Security
import XCTest
@testable import AttentionClientDuoPrototype

@MainActor
final class NativeGuidedJoinTests: XCTestCase {
    func testLostJoinReplyRestoresAndRetriesTheSameDeviceRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let first = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(first)
        var firstBody: Data?
        transport.handler = { _, method, body in
            XCTAssertEqual(method, "POST")
            let restored = try XCTUnwrap(NativeGuidedJoinStore(namespace: fixture.namespace,
                                                            transport: transport).loadAttempt())
            XCTAssertEqual(restored.deviceID, first.deviceID)
            XCTAssertEqual(restored.statusSecret, first.statusSecret)
            if firstBody == nil {
                firstBody = body
                throw URLError(.networkConnectionLost)
            }
            XCTAssertEqual(body, firstBody)
            return try fixture.pendingResponse()
        }
        do { _ = try await store.submit(); XCTFail("The first reply was lost") }
        catch is URLError {}
        let reopened = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let resumed = try reopened.prepare(fixture.invitation, deviceLabel: "Changed after interruption")
        XCTAssertEqual(resumed, first)
        let pending = try await reopened.submit()
        XCTAssertEqual(pending.phase, .pending)
        XCTAssertEqual(pending.approvalCode, "ABCDEF2345")
        XCTAssertNil(try reopened.approvedRecord())
    }

    func testApprovalBeforeLostReplyIsRecoveredWithThePersistedSecret() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { url, _, body in
            if url.path == "/enroll" { throw URLError(.networkConnectionLost) }
            XCTAssertEqual(url.path, "/enroll/status")
            let fields = try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: String]
            XCTAssertEqual(fields?["status_secret"], prepared.statusSecret)
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": prepared.deviceID])
        }
        do { _ = try await store.submit(); XCTFail("The reply must be lost") } catch is URLError {}
        let reopened = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let approved = try await reopened.checkApproval()
        XCTAssertEqual(approved.phase, .approved)
        let record = try XCTUnwrap(reopened.approvedRecord())
        XCTAssertEqual(record.personID, fixture.invitation.personID)
        XCTAssertEqual(record.deviceID, prepared.deviceID)
        _ = try NativeEnrollmentStore(service: fixture.namespace).material(from: record)
    }

    func testWrongPersonOrKeyApprovalCannotPublishAnApprovedInstallation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        for (person, device) in [("another-person", prepared.deviceID),
                                 (fixture.invitation.personID, String(repeating: "0", count: 64))] {
            transport.handler = { _, _, _ in
                try response(["state": "approved", "person_id": person, "device_id": device])
            }
            do { _ = try await store.checkApproval(); XCTFail("A different binding must not approve this device") }
            catch NativeJoinError.wrongApproval {}
            XCTAssertNil(try store.approvedRecord())
            XCTAssertEqual(try store.loadAttempt()?.phase, .prepared)
        }
    }

    func testUnknownResumePreservesSavedIdentityWithoutClaimingExpiryOrCreatingAJoin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let first = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(first)
        transport.handler = { _, _, _ in try response(["error": "expired"], status: 410) }
        let expired = try await store.submit()
        XCTAssertEqual(expired.phase, .expired)
        transport.handler = { url, _, _ in
            XCTAssertEqual(url.path, "/enroll/resume")
            return try response(["error": "not_found"], status: 404)
        }
        do { _ = try await store.checkApproval(); XCTFail("Unsupported or unknown recovery must remain unresolved") }
        catch NativeJoinError.unavailable {}
        XCTAssertEqual(try store.loadAttempt(), expired)
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        await flow.restore()
        XCTAssertEqual(flow.screen, .unreachable)
        XCTAssertEqual(try store.loadAttempt()?.deviceID, first.deviceID)
        XCTAssertEqual(try store.loadAttempt()?.statusSecret, first.statusSecret)
    }

    func testAnotherAccountInvitationCannotSilentlyReplaceSavedProgress() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: FakeTransport())
        let first = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(first)
        let other = try fixture.invitationWith(person: "another-person")
        XCTAssertThrowsError(try store.prepare(other, deviceLabel: "My phone"))
        XCTAssertEqual(try store.loadAttempt(), first)
    }

    func testFreshSameAccountLinkRefreshesSavedPendingStateWithoutAnotherJoin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        transport.handler = { _, _, _ in
            try response(["state": "pending", "approval_code": "ABCDEF2345", "expires_at": now - 1,
                          "status_expires_at": now + 86_400_000])
        }
        _ = try await store.submit()
        var statusChecks = 0
        let renewedDeadline = now + 86_400_000
        transport.handler = { url, method, body in
            if method == "GET" { return try response(["error": "invalid_request"], status: 400) }
            XCTAssertEqual(url.path, "/enroll/resume", "A fresh link must continue the original Join, not submit another")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: String])
            XCTAssertEqual(fields["status_secret"], original.statusSecret)
            statusChecks += 1
            return try response(["state": "pending", "person_id": fixture.invitation.personID,
                                 "device_id": original.deviceID, "approval_code": "FGHIJK2345", "expires_at": renewedDeadline,
                                 "status_expires_at": renewedDeadline + 86_400_000, "request_generation": 2])
        }
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        await flow.receive(fixture.url(try fixture.invitationWith(token: String(repeating: "2", count: 64))))
        XCTAssertEqual(statusChecks, 1)
        XCTAssertEqual(flow.screen, .pending)
        let saved = try XCTUnwrap(NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport).loadAttempt())
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.deviceID, original.deviceID)
        XCTAssertEqual(saved.statusSecret, original.statusSecret)
        XCTAssertEqual(saved.approvalCode, "FGHIJK2345")
        XCTAssertEqual(saved.approvalExpiresAt, renewedDeadline)
    }

    func testLegacyExpiredJoinResumesAutomaticallyAfterLostReplyAndRestart() async throws {
        for lostFirstReply in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let transport = FakeTransport()
            let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
            var original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
            fixture.retainForCleanup(original)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            original.phase = .expired
            original.approvalCode = lostFirstReply ? nil : "ABCDEF2345"
            original.approvalExpiresAt = lostFirstReply ? nil : now - 60_000
            original.statusExpiresAt = lostFirstReply ? nil : now + 86_400_000
            try fixture.saveLegacyAttempt(original)
            var firstBody: Data?
            var renewalCount = 0
            let renewedDeadline = now + 86_400_000
            transport.handler = { url, method, body in
                XCTAssertEqual(url.path, "/enroll/resume")
                XCTAssertEqual(method, "POST")
                let body = try XCTUnwrap(body)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
                XCTAssertEqual(fields["status_secret"], original.statusSecret)
                XCTAssertNil(fields["invite_token"], "Renewal cannot spend another invitation")
                XCTAssertNotNil(fields["public_certificate"])
                renewalCount += 1
                if firstBody == nil {
                    firstBody = body
                    throw URLError(.networkConnectionLost)
                }
                XCTAssertEqual(body, firstBody, "A lost renewal response must replay the original bound request")
                return try response(["state": "pending", "person_id": fixture.invitation.personID,
                                     "device_id": original.deviceID, "approval_code": "FGHIJK2345",
                                     "expires_at": renewedDeadline, "status_expires_at": renewedDeadline + 86_400_000,
                                     "request_generation": 2])
            }
            let interrupted = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
            await interrupted.restore()
            XCTAssertEqual(interrupted.screen, .unreachable)
            XCTAssertNil(interrupted.currentApprovalCode)
            XCTAssertEqual(try store.loadAttempt(), original)
            let reopenedStore = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
            let reopened = NativeGuidedJoinCoordinator(store: reopenedStore, deviceName: "My phone")
            await reopened.restore()
            XCTAssertEqual(renewalCount, 2)
            XCTAssertEqual(reopened.screen, .pending)
            XCTAssertEqual(reopened.currentApprovalCode, "FGHIJK2345")
            reopened.invalidateApprovalObservation()
            XCTAssertNil(reopened.currentApprovalCode, "Returning offline cannot advertise a saved code as current")
            let resumed = try XCTUnwrap(reopenedStore.loadAttempt())
            XCTAssertEqual(resumed.id, original.id)
            XCTAssertEqual(resumed.deviceID, original.deviceID)
            XCTAssertEqual(resumed.certificateDER, original.certificateDER)
            XCTAssertEqual(resumed.statusSecret, original.statusSecret)
            XCTAssertEqual(resumed.approvalCode, "FGHIJK2345")
            XCTAssertEqual(resumed.approvalExpiresAt, renewedDeadline)
            XCTAssertEqual(resumed.requestGeneration, 2)
            XCTAssertNil(try reopenedStore.approvedRecord())
        }
    }

    func testLostInitialReplyRestoresPreparedRequestThroughResumeAfterStatusHorizon() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        var initialPosts = 0
        transport.handler = { url, _, _ in
            XCTAssertEqual(url.path, "/enroll")
            initialPosts += 1
            // The server accepted the original Join; its response was lost.
            throw URLError(.networkConnectionLost)
        }
        do { _ = try await store.submit(); XCTFail("The first reply is lost") }
        catch is URLError {}
        let interrupted = try XCTUnwrap(store.loadAttempt())
        XCTAssertEqual(interrupted.phase, .prepared)
        XCTAssertNil(interrupted.approvalCode)
        XCTAssertNil(interrupted.requestGeneration)
        // Model the same stored request after long offline time, without
        // changing the prepared phase into an observed expired response.
        var fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(interrupted)) as? [String: Any])
        var invitation = try XCTUnwrap(fields["invitation"] as? [String: Any])
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        invitation["expires_at"] = now - 172_800_000
        fields["invitation"] = invitation
        let aged = try JSONDecoder().decode(NativeJoinAttempt.self, from: JSONSerialization.data(withJSONObject: fields))
        try fixture.saveLegacyAttempt(aged)
        var statusQueries = 0
        var resumes = 0
        transport.handler = { url, _, body in
            if url.path == "/enroll/status" {
                statusQueries += 1
                return try response(["error": "not_found"], status: 404)
            }
            XCTAssertEqual(url.path, "/enroll/resume", "A spent invitation cannot be replayed after a lost reply")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: String])
            XCTAssertEqual(fields["status_secret"], original.statusSecret)
            XCTAssertNil(fields["invite_token"])
            let certificate = try XCTUnwrap(fields["public_certificate"])
            XCTAssertEqual(NativeEnrollmentSettings.certificateDER(from: certificate), original.certificateDER)
            resumes += 1
            if resumes == 1 { throw URLError(.networkConnectionLost) }
            return try response(["state": "pending", "person_id": original.invitation.personID,
                                 "device_id": original.deviceID, "approval_code": "FGHIJK2345",
                                 "expires_at": now + 86_400_000, "status_expires_at": now + 172_800_000,
                                 "request_generation": 2])
        }
        let restoring = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        await restoring.restore()
        XCTAssertEqual(restoring.screen, .unreachable)
        XCTAssertEqual(try store.loadAttempt(), aged)
        let reopened = NativeGuidedJoinCoordinator(
            store: NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport), deviceName: "My phone")
        await reopened.restore()
        XCTAssertEqual(reopened.screen, .pending)
        XCTAssertEqual(statusQueries, 2)
        XCTAssertEqual(resumes, 2)
        XCTAssertEqual(initialPosts, 1)
        let recovered = try XCTUnwrap(store.loadAttempt())
        XCTAssertEqual(recovered.id, original.id)
        XCTAssertEqual(recovered.identityLabel, original.identityLabel)
        XCTAssertEqual(recovered.statusSecret, original.statusSecret)
        XCTAssertEqual(recovered.deviceID, original.deviceID)
        XCTAssertEqual(recovered.certificateDER, original.certificateDER)
        XCTAssertEqual(recovered.requestGeneration, 2)
        XCTAssertEqual(recovered.approvalCode, "FGHIJK2345")
    }

    func testRenewalCannotAdoptAnotherPersonOrDevice() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        var original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        original.phase = .expired
        original.approvalCode = "ABCDEF2345"
        original.approvalExpiresAt = now - 1
        original.statusExpiresAt = now + 86_400_000
        try fixture.saveLegacyAttempt(original)
        for (person, device) in [("another-person", original.deviceID),
                                 (fixture.invitation.personID, String(repeating: "0", count: 64))] {
            transport.handler = { _, _, _ in
                try response(["state": "pending", "person_id": person, "device_id": device,
                              "approval_code": "FGHIJK2345", "expires_at": now + 86_400_000,
                              "status_expires_at": now + 172_800_000, "request_generation": 2])
            }
            do { _ = try await store.checkApproval(); XCTFail("Renewal must preserve the original account/key binding") }
            catch NativeJoinError.wrongApproval {}
            XCTAssertEqual(try store.loadAttempt(), original)
            XCTAssertNil(try store.approvedRecord())
        }
    }

    func testExpiredRequestWithCancellationIntentCancelsWithoutRenewing() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        var original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        original.phase = .expired
        original.approvalCode = "ABCDEF2345"
        original.approvalExpiresAt = 1
        original.statusExpiresAt = 2
        original.cancellationRequested = true
        try fixture.saveLegacyAttempt(original)
        var cancellations = 0
        transport.handler = { url, _, _ in
            XCTAssertEqual(url.path, "/enroll/cancel", "Cancellation must not create a fresh approval generation")
            cancellations += 1
            return try response(["state": "cancelled"])
        }
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        await flow.restore()
        await flow.retry()
        XCTAssertEqual(cancellations, 1)
        XCTAssertEqual(try store.loadAttempt()?.phase, .cancelled)
        XCTAssertEqual(try store.loadAttempt()?.deviceID, original.deviceID)
        XCTAssertEqual(try store.loadAttempt()?.cancellationRequested, true)
    }

    func testDeniedRevokedAndCancelledRequestsStayTerminalOnRestore() async throws {
        for state in ["denied", "revoked", "cancelled"] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let transport = FakeTransport()
            let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
            let original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
            fixture.retainForCleanup(original)
            transport.handler = { _, _, _ in try fixture.pendingResponse() }
            _ = try await store.submit()
            transport.handler = { _, _, _ in try response(["state": state]) }
            let stopped = try await store.checkApproval()
            XCTAssertTrue(stopped.isTerminal)
            transport.handler = { _, _, _ in
                XCTFail("Owner refusal, revocation and cancellation must not automatically renew")
                throw NativeJoinError.unavailable
            }
            let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
            await flow.restore()
            await flow.retry()
            XCTAssertEqual(try store.loadAttempt(), stopped)
        }
    }

    func testDelayedResumeCannotOverwriteNewerGenerationOrCommittedCancellation() async throws {
        for cancelBeforeLateReply in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let transport = FakeTransport()
            let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
            var original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
            fixture.retainForCleanup(original)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            original.phase = .pending
            original.approvalCode = "ABCDEF2345"
            original.approvalExpiresAt = now + 60_000
            original.statusExpiresAt = now + 86_400_000
            original.requestGeneration = 1
            try fixture.saveLegacyAttempt(original)
            let (started, start) = AsyncStream<Void>.makeStream()
            let (released, release) = AsyncStream<Void>.makeStream()
            var statusCalls = 0
            transport.handler = { url, _, _ in
                if url.path == "/enroll/cancel" {
                    return try response(["state": "cancelled", "request_generation": 2])
                }
                XCTAssertEqual(url.path, "/enroll/resume")
                statusCalls += 1
                if statusCalls == 1 {
                    start.yield()
                    for await _ in released { break }
                    return try response(["state": "pending", "person_id": fixture.invitation.personID,
                                         "device_id": original.deviceID, "approval_code": "ABCDEF2345",
                                         "expires_at": now + 60_000, "status_expires_at": now + 86_400_000,
                                         "request_generation": 1])
                }
                return try response(["state": "pending", "person_id": fixture.invitation.personID,
                                     "device_id": original.deviceID, "approval_code": "FGHIJK2345",
                                     "expires_at": now + 86_400_000, "status_expires_at": now + 172_800_000,
                                     "request_generation": 2])
            }
            let delayed = Task { try await store.checkApproval() }
            for await _ in started { break }
            let latest = try await store.checkApproval()
            XCTAssertEqual(latest.requestGeneration, 2)
            if cancelBeforeLateReply { _ = try await store.cancel() }
            release.yield()
            let late = try await delayed.value
            let saved = try XCTUnwrap(store.loadAttempt())
            XCTAssertEqual(late, saved)
            XCTAssertEqual(saved.requestGeneration, 2)
            XCTAssertEqual(saved.approvalCode, "FGHIJK2345")
            XCTAssertEqual(saved.phase, cancelBeforeLateReply ? .cancelled : .pending)
        }
    }

    func testEqualGenerationCannotChangeTheApprovalTuple() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        var original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        original.phase = .pending
        original.approvalCode = "ABCDEF2345"
        original.approvalExpiresAt = now + 86_400_000
        original.statusExpiresAt = now + 172_800_000
        original.requestGeneration = 2
        try fixture.saveLegacyAttempt(original)
        transport.handler = { _, _, _ in
            try response(["state": "pending", "person_id": fixture.invitation.personID,
                          "device_id": original.deviceID, "approval_code": "FGHIJK2345",
                          "expires_at": now + 86_400_000, "status_expires_at": now + 172_800_000,
                          "request_generation": 2])
        }
        do { _ = try await store.checkApproval(); XCTFail("An unchanged generation cannot acquire a different code") }
        catch NativeJoinError.invalidResponse {}
        XCTAssertEqual(try store.loadAttempt(), original)
    }

    func testStaleCancellationReconcilesCurrentTupleAndKeepsIntentAfterLostReply() async throws {
        for lostFirstReply in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanup() }
            let transport = FakeTransport()
            let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
            var original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
            fixture.retainForCleanup(original)
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            original.phase = .expired
            original.approvalCode = lostFirstReply ? nil : "ABCDEF2345"
            original.approvalExpiresAt = lostFirstReply ? nil : now - 172_800_000
            original.statusExpiresAt = lostFirstReply ? nil : now - 86_400_000
            original.requestGeneration = lostFirstReply ? nil : 1
            try fixture.saveLegacyAttempt(original)
            var calls = 0
            var sentCurrentTuple: Data?
            transport.handler = { url, _, body in
                XCTAssertEqual(url.path, "/enroll/cancel", "Cancellation reconciliation never invokes renewal")
                XCTAssertEqual(try store.loadAttempt()?.cancellationRequested, true)
                let body = try XCTUnwrap(body)
                let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
                XCTAssertEqual(fields["status_secret"] as? String, original.statusSecret)
                XCTAssertEqual(fields["expected_device_id"] as? String, original.deviceID)
                calls += 1
                if calls == 1 {
                    let suppliedCode = try XCTUnwrap(fields["approval_code"] as? String)
                    XCTAssertEqual(suppliedCode.utf8.count, 10)
                    XCTAssertTrue(suppliedCode.utf8.allSatisfy { (65...90).contains($0) || (50...55).contains($0) })
                    XCTAssertGreaterThan(try XCTUnwrap(fields["expected_expires_at"] as? Int64), 0)
                    return try response(["error": "stale_request", "current": ["state": "expired",
                                         "person_id": fixture.invitation.personID, "device_id": original.deviceID,
                                         "approval_code": "FGHIJK2345", "expires_at": now - 60_000,
                                         "status_expires_at": now + 86_400_000, "request_generation": 2]], status: 409)
                }
                XCTAssertEqual(fields["approval_code"] as? String, "FGHIJK2345")
                XCTAssertEqual(fields["expected_expires_at"] as? Int64, now - 60_000)
                if calls == 2 {
                    sentCurrentTuple = body
                    throw URLError(.networkConnectionLost)
                }
                XCTAssertEqual(body, sentCurrentTuple)
                return try response(["state": "cancelled", "request_generation": 2])
            }
            let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
            await flow.cancelRequest()
            XCTAssertEqual(flow.screen, .unreachable)
            let reopenedStore = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
            XCTAssertEqual(try reopenedStore.loadAttempt()?.requestGeneration, 2)
            XCTAssertEqual(try reopenedStore.loadAttempt()?.cancellationRequested, true)
            let reopened = NativeGuidedJoinCoordinator(store: reopenedStore, deviceName: "My phone")
            await reopened.restore()
            XCTAssertEqual(calls, 3)
            XCTAssertEqual(reopened.screen, .cancelled)
            XCTAssertEqual(try reopenedStore.loadAttempt()?.phase, .cancelled)
        }
    }

    func testCanonicallySimilarButDifferentWireAccountCannotApproveThisInstallation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let invitation = try fixture.invitationWith(person: "caf\u{00e9}")
        let prepared = try store.prepare(invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": "cafe\u{0301}", "device_id": prepared.deviceID])
        }
        do { _ = try await store.checkApproval(); XCTFail("Approval must name the exact account from the invitation") }
        catch NativeJoinError.wrongApproval {}
        XCTAssertNil(try store.approvedRecord())
        XCTAssertEqual(try store.loadAttempt()?.phase, .prepared)
    }

    func testDestinationCheckDoesNotDiscloseTheInvitationOrCreateARequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        transport.handler = { url, method, body in
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            XCTAssertNil(url.query)
            XCTAssertNil(url.fragment)
            XCTAssertFalse(url.absoluteString.contains(fixture.invitation.inviteToken))
            return try response(["error": "invalid_request"], status: 400)
        }
        try await store.verifyDestination(fixture.invitation)
        XCTAssertNil(try store.loadAttempt())
    }

    func testTamperedTrustOrRelayDestinationIsRejected() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var fields = fixture.payload
        fields["ca_sha256"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try NativeJoinInvitation.decodePayload(JSONSerialization.data(withJSONObject: fields)))
        fields = fixture.payload
        fields["relay_url"] = "wss://another-server.test:18443/relay"
        XCTAssertThrowsError(try NativeJoinInvitation.decodePayload(JSONSerialization.data(withJSONObject: fields)))
    }

    func testConnectedScreenWaitsForOwnerApprovalAndRelayProgress() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        var relayReached = false
        flow.connectApproved = { _ in relayReached }
        transport.handler = { url, method, _ in
            if method == "GET" { return try response(["error": "invalid_request"], status: 400) }
            if url.path == "/enroll" { return try fixture.pendingResponse() }
            let saved = try XCTUnwrap(store.loadAttempt())
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": saved.deviceID])
        }
        await flow.receive(fixture.url())
        XCTAssertEqual(flow.screen, .confirmation)
        XCTAssertNil(try store.loadAttempt())
        await flow.join()
        fixture.retainForCleanup(try XCTUnwrap(store.loadAttempt()))
        XCTAssertEqual(flow.screen, .pending)
        await flow.retry()
        XCTAssertEqual(flow.screen, .approvedFinishing)
        XCTAssertTrue(flow.isShowing)
        relayReached = true
        await flow.retry()
        XCTAssertEqual(flow.screen, .connected)
    }

    func testOfflineInvitationCheckCanRetryWithoutSendingAJoinRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        var reachable = false
        transport.handler = { _, method, body in
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            if !reachable { throw URLError(.notConnectedToInternet) }
            return try response(["error": "invalid_request"], status: 400)
        }
        await flow.receive(fixture.url())
        XCTAssertEqual(flow.screen, .unreachable)
        XCTAssertNil(try store.loadAttempt())
        reachable = true
        await flow.retry()
        XCTAssertEqual(flow.screen, .confirmation)
        XCTAssertNil(try store.loadAttempt())
    }

    func testUnansweredNotificationPromptDoesNotHoldTheInbox() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        flow.connectApproved = { _ in true }
        transport.handler = { _, method, _ in
            if method == "GET" { return try response(["error": "invalid_request"], status: 400) }
            let saved = try XCTUnwrap(store.loadAttempt())
            let deadline = Int64(Date().timeIntervalSince1970 * 1000) + 600_000
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": saved.deviceID, "approval_code": "ABCDEF2345",
                                 "expires_at": deadline, "status_expires_at": deadline + 86_400_000])
        }
        await flow.receive(fixture.url())
        await flow.join()
        fixture.retainForCleanup(try XCTUnwrap(store.loadAttempt()))
        XCTAssertEqual(flow.screen, .connected)
        flow.continueConnected()
        let (started, start) = AsyncStream<Void>.makeStream()
        let (released, release) = AsyncStream<Void>.makeStream()
        flow.notificationChoice = { enabled in
            XCTAssertTrue(enabled)
            start.yield()
            for await _ in released { break }
        }
        let choosing = Task { await flow.chooseNotifications(true) }
        for await _ in started { break }
        XCTAssertFalse(flow.isShowing, "The real inbox is available while notification permission is unanswered")
        release.yield()
        await choosing.value
    }

    func testEstablishedInstallationKeepsItsInboxAvailableAfterOfflineRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let records = NativeEnrollmentStore(service: fixture.namespace)
        try records.markForegroundRelayConfirmed(for: prepared.deviceID)
        try records.markNotificationExplanationSeen(for: prepared.deviceID)
        let reopened = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        reopened.connectApproved = { _ in false }
        await reopened.restore()
        XCTAssertFalse(reopened.isShowing)
        XCTAssertNotEqual(reopened.screen, .connected, "Offline restore must not claim current connectivity")
        XCTAssertEqual(try store.approvedRecord()?.deviceID, prepared.deviceID)
    }

    func testFailedRemoteRemovalCannotReplaceTheCurrentAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, method, _ in
            if method == "GET" { return try response(["error": "invalid_request"], status: 400) }
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let old = try store.approvedRecord()
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        let other = try fixture.invitationWith(person: "another-person")
        await flow.receive(fixture.url(other))
        XCTAssertEqual(flow.screen, .existingAccount)
        XCTAssertEqual(try store.approvedRecord(), old)
        flow.considerReplacement()
        transport.removalHandler = { _, _, _, _ in throw URLError(.networkConnectionLost) }
        await flow.confirmReplacement()
        XCTAssertEqual(flow.screen, .replacementConfirmation)
        XCTAssertEqual(try store.approvedRecord(), old)
    }

    func testEarlierApprovedInstallationKeepsItsDurableInboxOfflineAfterUpgrade() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let current = try XCTUnwrap(store.approvedRecord())
        var earlier = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(current)) as? [String: Any])
        for name in ["foregroundRelayConfirmed", "notificationExplanationSeen", "serverDisplayName", "accountDisplayName"] {
            earlier.removeValue(forKey: name)
        }
        let oldData = try JSONSerialization.data(withJSONObject: earlier)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: fixture.namespace,
                     kSecAttrAccount as String: "current-installation"]
        guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: oldData] as CFDictionary) == errSecSuccess else {
            throw NativeEnrollmentError.identityStorage
        }
        let restoring = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        restoring.connectApproved = { _ in false }
        await restoring.restore()
        XCTAssertFalse(restoring.isShowing, "The earlier joined account can still read its saved inbox offline")
        XCTAssertNotEqual(restoring.screen, .connected)
        XCTAssertEqual(try store.approvedRecord()?.deviceID, current.deviceID)
    }

    func testLostCancellationReplyResumesTheExactRequestAndReportsConfirmedCancellation() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        transport.handler = { _, _, _ in try fixture.pendingResponse() }
        let pending = try await store.submit()
        var sent: Data?
        transport.handler = { url, _, body in
            XCTAssertEqual(url.path, "/enroll/cancel")
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: Any])
            XCTAssertEqual(Set(fields.keys), ["status_secret", "approval_code", "expected_device_id", "expected_expires_at"])
            XCTAssertEqual(fields["expected_device_id"] as? String, original.deviceID)
            XCTAssertEqual(fields["approval_code"] as? String, pending.approvalCode)
            XCTAssertEqual(fields["expected_expires_at"] as? Int64, pending.approvalExpiresAt)
            if sent == nil { sent = body; throw URLError(.networkConnectionLost) }
            XCTAssertEqual(body, sent)
            return try response(["state": "cancelled"])
        }
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        await flow.cancelRequest()
        XCTAssertNotEqual(flow.screen, .cancelled)
        XCTAssertTrue(try XCTUnwrap(store.loadAttempt()).cancellationRequested == true)
        let reopened = NativeGuidedJoinCoordinator(store: NativeGuidedJoinStore(namespace: fixture.namespace,
                                                                                transport: transport), deviceName: "My phone")
        await reopened.restore()
        XCTAssertEqual(reopened.screen, .cancelled)
        XCTAssertNil(try store.approvedRecord())
    }

    func testApprovalWinningCancellationRaceStaysApprovedAndNeedsRelayProof() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, _, _ in try fixture.pendingResponse() }
        _ = try await store.submit()
        transport.handler = { url, _, _ in
            XCTAssertEqual(url.path, "/enroll/cancel")
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": prepared.deviceID])
        }
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        flow.connectApproved = { _ in false }
        await flow.cancelRequest()
        XCTAssertEqual(flow.screen, .approvedFinishing)
        XCTAssertEqual(try store.approvedRecord()?.deviceID, prepared.deviceID)
        XCTAssertNotEqual(flow.screen, .cancelled)
    }

    func testLostRemovalReplyKeepsOriginalKeyAndResumesBeforeFreshReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let record = try XCTUnwrap(store.approvedRecord())
        let replacement = try fixture.invitationWith(token: String(repeating: "2", count: 64))
        var calls = 0
        transport.removalHandler = { url, body, root, identity in
            XCTAssertEqual(url.path, "/device/remove")
            XCTAssertEqual(root, record.trustedRootDER)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(fields, ["expected_device_id": prepared.deviceID])
            var certificate: SecCertificate?
            XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
            let cert = try XCTUnwrap(certificate)
            XCTAssertTrue(DeviceCertificateBinding.matches(SecCertificateCopyData(cert) as Data,
                                                           expectedDeviceID: prepared.deviceID))
            calls += 1
            if calls == 1 { throw URLError(.networkConnectionLost) }
            return try response(["state": "removed", "person_id": fixture.invitation.personID,
                                 "device_id": prepared.deviceID, "enrollment_revision": 2])
        }
        do { try await store.removeCurrentAccount(record, replacement: replacement); XCTFail("Lost reply") }
        catch is URLError {}
        XCTAssertEqual(try store.approvedRecord(), record)
        _ = try NativeEnrollmentStore(service: fixture.namespace).material(from: record)
        let reopenedStore = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let flow = NativeGuidedJoinCoordinator(store: reopenedStore, deviceName: "My phone")
        await flow.restore()
        XCTAssertEqual(flow.screen, .replacementConfirmation)
        await flow.keepCurrentAccount()
        XCTAssertTrue(flow.isShowing, "An uncertain removal cannot be presented as a retained active account")
        await flow.confirmReplacement()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(flow.screen, .confirmation)
        XCTAssertNil(try reopenedStore.approvedRecord())
        let restoringAfterReceipt = NativeGuidedJoinCoordinator(store: reopenedStore, deviceName: "My phone")
        await restoringAfterReceipt.restore()
        XCTAssertEqual(restoringAfterReceipt.screen, .confirmation)
        let next = try reopenedStore.prepare(replacement, deviceLabel: "My phone")
        fixture.retainForCleanup(next)
        XCTAssertNotEqual(next.deviceID, prepared.deviceID, "A revoked identity cannot become the new installation")
    }

    func testWrongRemovalReceiptDoesNotClearTheJoinedAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let record = try XCTUnwrap(store.approvedRecord())
        transport.removalHandler = { _, _, _, _ in
            try response(["state": "removed", "person_id": "another-person",
                          "device_id": prepared.deviceID, "enrollment_revision": 2])
        }
        do {
            try await store.removeCurrentAccount(record, replacement: fixture.invitationWith(person: "another-person"))
            XCTFail("A different person's receipt cannot remove this account")
        } catch NativeJoinError.wrongApproval {}
        XCTAssertEqual(try store.approvedRecord(), record)
        XCTAssertFalse(try XCTUnwrap(store.departure()).removed)
    }

    func testRestartAfterReplacementRequestSavedBeforeOldReceiptCleanupKeepsTheNewRequest() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let original = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(original)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": original.deviceID])
        }
        _ = try await store.checkApproval()
        let record = try XCTUnwrap(store.approvedRecord())
        let invitation = try fixture.invitationWith(token: String(repeating: "2", count: 64))
        transport.removalHandler = { _, _, _, _ in
            try response(["state": "removed", "person_id": fixture.invitation.personID,
                          "device_id": original.deviceID, "enrollment_revision": 2])
        }
        try await store.removeCurrentAccount(record, replacement: invitation)
        let receipt = try XCTUnwrap(store.departure())
        let next = try store.prepare(invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(next)
        // Recreate the interruption between the successor's durable write and
        // deletion of the already-confirmed old removal receipt.
        let attributes: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrService as String: fixture.namespace,
                                        kSecAttrAccount as String: "guided-departure",
                                        kSecValueData as String: try JSONEncoder().encode(receipt)]
        guard SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess else {
            throw NativeEnrollmentError.identityStorage
        }
        var retriedBody: [String: String]?
        transport.handler = { url, _, body in
            if url.path == "/enroll/status" || url.path == "/enroll/resume" {
                return try response(["error": "not_found"], status: 404)
            }
            retriedBody = try JSONSerialization.jsonObject(with: XCTUnwrap(body)) as? [String: String]
            return try fixture.pendingResponse()
        }
        let reopened = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let flow = NativeGuidedJoinCoordinator(store: reopened, deviceName: "My phone")
        await flow.restore()
        XCTAssertEqual(flow.screen, .pending)
        XCTAssertEqual(try reopened.loadAttempt()?.id, next.id)
        XCTAssertEqual(retriedBody?["status_secret"], next.statusSecret)
        XCTAssertNil(try reopened.departure())
        XCTAssertNil(try reopened.approvedRecord(), "Old removal proof does not approve the replacement")
    }

    func testStandaloneDisconnectSurvivesLostReplyAndReconnectCreatesFreshIdentity() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let (original, record) = try await approvedInstallation(fixture, store: store, transport: transport)
        var removalCalls = 0
        transport.removalHandler = { url, body, root, identity in
            XCTAssertEqual(url.path, "/device/remove")
            XCTAssertEqual(root, record.trustedRootDER)
            let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(fields, ["expected_device_id": original.deviceID])
            let saved = try XCTUnwrap(store.departure())
            XCTAssertNil(saved.replacement, "Standalone removal must not require another invitation")
            XCTAssertFalse(saved.removed, "The intent is durable before the server call")
            var certificate: SecCertificate?
            XCTAssertEqual(SecIdentityCopyCertificate(identity, &certificate), errSecSuccess)
            XCTAssertTrue(DeviceCertificateBinding.matches(
                SecCertificateCopyData(try XCTUnwrap(certificate)) as Data,
                expectedDeviceID: original.deviceID))
            removalCalls += 1
            if removalCalls == 1 { throw URLError(.networkConnectionLost) }
            return try response(["state": "removed", "person_id": fixture.invitation.personID,
                                 "device_id": original.deviceID, "enrollment_revision": 3])
        }

        try store.prepareAccountDeparture(record)
        XCTAssertEqual(removalCalls, 0, "Preparing the durable intent does not contact the server")
        do {
            try await store.removeCurrentAccount(record)
            XCTFail("The first removal reply is lost")
        } catch is URLError {}
        XCTAssertEqual(try store.approvedRecord(), record)
        XCTAssertFalse(try XCTUnwrap(store.departure()).removed)

        let reopened = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let blockedFlow = NativeGuidedJoinCoordinator(store: reopened, deviceName: "My phone", isShowing: false)
        await blockedFlow.receive(fixture.url(try fixture.invitationWith(token: String(repeating: "2", count: 64))))
        XCTAssertFalse(blockedFlow.isShowing, "A new invitation cannot bypass unconfirmed removal")
        XCTAssertEqual(removalCalls, 1)
        XCTAssertEqual(try reopened.approvedRecord(), record)

        try await reopened.removeCurrentAccount(record)
        let receipt = try XCTUnwrap(reopened.departure())
        XCTAssertTrue(receipt.removed)
        XCTAssertNil(receipt.replacement)
        XCTAssertNil(try reopened.approvedRecord())
        XCTAssertEqual(removalCalls, 2)

        let next = try reopened.prepare(fixture.invitationWith(token: String(repeating: "3", count: 64)),
                                        deviceLabel: "My phone")
        fixture.retainForCleanup(next)
        XCTAssertNotEqual(next.deviceID, original.deviceID,
                          "A confirmed removal is followed by a new installation identity")
        XCTAssertEqual(try reopened.departure()?.record.deviceID, original.deviceID,
                       "The disconnected profile remains associated with its original device and data")

        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": next.deviceID])
        }
        _ = try await reopened.checkApproval()
        let nextRecord = try XCTUnwrap(reopened.approvedRecord())
        try reopened.prepareAccountDeparture(nextRecord)
        XCTAssertEqual(try reopened.departure()?.record.deviceID, next.deviceID,
                       "A later disconnect belongs to the newly approved installation")
        XCTAssertFalse(try XCTUnwrap(reopened.departure()).removed)
    }

    func testFullInvitationPasteChecksDestinationBeforeAJoinAndReadsDisplayOnlyLabels() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var payload = fixture.payload
        payload["person_label"] = "Mike"
        payload["inviter_label"] = "Server owner"
        let invitation = try NativeJoinInvitation.decodePayload(JSONSerialization.data(withJSONObject: payload))
        let transport = FakeTransport()
        transport.handler = { _, method, body in
            XCTAssertEqual(method, "GET")
            XCTAssertNil(body)
            return try response(["error": "invalid_request"], status: 400)
        }
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        await flow.pasteInvitation(" \n" + fixture.url(invitation).absoluteString + "\n")
        XCTAssertEqual(flow.screen, .confirmation)
        XCTAssertEqual(flow.invitation?.claimedAccountLabel, "Mike")
        XCTAssertEqual(flow.invitation?.approvingOwnerLabel, "Server owner")
        XCTAssertEqual(flow.invitation?.personID, fixture.invitation.personID)
        XCTAssertNil(try store.loadAttempt())
    }

    func testKeepingTheCurrentAccountWorksWhenInvitationOpensBeforeStartupRestore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, method, _ in
            if method == "GET" { return try response(["error": "invalid_request"], status: 400) }
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let records = NativeEnrollmentStore(service: fixture.namespace)
        try records.markForegroundRelayConfirmed(for: prepared.deviceID)
        try records.markNotificationExplanationSeen(for: prepared.deviceID)
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        var openedAccount: String?
        flow.connectApproved = { record in openedAccount = record.personID; return false }
        await flow.receive(fixture.url(try fixture.invitationWith(person: "another-person")))
        XCTAssertEqual(flow.screen, .existingAccount)
        await flow.keepCurrentAccount()
        XCTAssertEqual(openedAccount, fixture.invitation.personID)
        XCTAssertFalse(flow.isShowing, "Keeping the original account reopens its real durable inbox even offline")
        XCTAssertEqual(try store.approvedRecord()?.personID, fixture.invitation.personID)
    }

    func testDelayedStartupRestoreCannotReplaceTheInvitationThePersonJustOpened() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let transport = FakeTransport()
        let store = NativeGuidedJoinStore(namespace: fixture.namespace, transport: transport)
        let prepared = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(prepared)
        transport.handler = { _, method, _ in
            if method == "GET" { return try response(["error": "invalid_request"], status: 400) }
            return try response(["state": "approved", "person_id": fixture.invitation.personID,
                                 "device_id": prepared.deviceID])
        }
        _ = try await store.checkApproval()
        let flow = NativeGuidedJoinCoordinator(store: store, deviceName: "My phone")
        var openedSavedAccount = false
        flow.connectApproved = { _ in openedSavedAccount = true; return true }
        let next = try fixture.invitationWith(person: "another-person")
        await flow.receive(fixture.url(next))
        await flow.restore()
        XCTAssertEqual(flow.screen, .existingAccount, "The deliberate account choice stays visible")
        XCTAssertEqual(flow.invitation?.personID, next.personID)
        XCTAssertTrue(flow.isShowing)
        XCTAssertFalse(openedSavedAccount, "Startup restore must not override the explicit invitation choice")
    }

    private final class FakeTransport: NativeJoinTransport {
        var handler: ((URL, String, Data?) async throws -> NativeJoinResponse)?
        var removalHandler: (@MainActor (URL, Data, Data, SecIdentity) async throws -> NativeJoinResponse)?
        func request(_ url: URL, method: String, body: Data?, rootDER: Data) async throws -> NativeJoinResponse {
            guard let handler else { throw NativeJoinError.unavailable }
            return try await handler(url, method, body)
        }
        func remove(_ url: URL, body: Data, rootDER: Data, identity: SecIdentity) async throws -> NativeJoinResponse {
            guard let removalHandler else { throw NativeJoinError.unavailable }
            return try await removalHandler(url, body, rootDER, identity)
        }
    }

    private func approvedInstallation(_ fixture: Fixture,
                                      store: NativeGuidedJoinStore,
                                      transport: FakeTransport) async throws -> (NativeJoinAttempt, NativeEnrollmentRecord) {
        let attempt = try store.prepare(fixture.invitation, deviceLabel: "My phone")
        fixture.retainForCleanup(attempt)
        transport.handler = { _, _, _ in
            try response(["state": "approved", "person_id": fixture.invitation.personID,
                          "device_id": attempt.deviceID])
        }
        _ = try await store.checkApproval()
        return (attempt, try XCTUnwrap(store.approvedRecord()))
    }

    private final class Fixture {
        let namespace = "Harklight.guided-join-test." + UUID().uuidString
        let payload: [String: Any]
        let invitation: NativeJoinInvitation
        private var labels: Set<String> = []
        private let approvalDeadline = Int64(Date().timeIntervalSince1970 * 1000) + 600_000

        init() throws {
            let root = try NativeInstallationIdentityStore(namespace: namespace + ".fixture-root").loadOrCreate()
            labels.insert(root.label)
            let pem = "-----BEGIN CERTIFICATE-----\n" + root.certificateDER.base64EncodedString() +
                "\n-----END CERTIFICATE-----\n"
            payload = ["v": 1, "person_id": "invited-person", "server_name": "relay.example.test",
                       "enrollment_url": "https://relay.example.test:18444/enroll",
                       "relay_url": "wss://relay.example.test:18443/relay", "ca_pem": pem,
                       "ca_sha256": SHA256.hash(data: root.certificateDER).map { String(format: "%02x", $0) }.joined(),
                       "invite_token": String(repeating: "1", count: 64),
                       "expires_at": Int64(Date().timeIntervalSince1970 * 1000) + 1_800_000]
            invitation = try NativeJoinInvitation.decodePayload(JSONSerialization.data(withJSONObject: payload))
        }

        func invitationWith(token: String? = nil, person: String? = nil) throws -> NativeJoinInvitation {
            var next = payload
            if let token { next["invite_token"] = token }
            if let person { next["person_id"] = person }
            return try NativeJoinInvitation.decodePayload(JSONSerialization.data(withJSONObject: next))
        }

        func pendingResponse() throws -> NativeJoinResponse {
            let deadline = approvalDeadline
            return try response(["state": "pending", "approval_code": "ABCDEF2345", "expires_at": deadline,
                                 "status_expires_at": deadline + 86_400_000])
        }

        func url(_ value: NativeJoinInvitation? = nil) -> URL {
            let data = try! JSONEncoder().encode(value ?? invitation)
            let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return URL(string: "harklight://join#" + encoded)!
        }

        func retainForCleanup(_ attempt: NativeJoinAttempt) { labels.insert(attempt.identityLabel) }

        // Model the durable format written by the previously shipped app,
        // including an expired request retained across an app upgrade.
        func saveLegacyAttempt(_ attempt: NativeJoinAttempt) throws {
            let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: namespace,
                                       kSecAttrAccount as String: "guided-request"]
            let status = SecItemUpdate(query as CFDictionary,
                                      [kSecValueData as String: try JSONEncoder().encode(attempt)] as CFDictionary)
            guard status == errSecSuccess else { throw NativeEnrollmentError.identityStorage }
        }

        func cleanup() {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: namespace] as CFDictionary)
            for label in labels {
                SecItemDelete([kSecClass as String: kSecClassCertificate, kSecAttrLabel as String: label] as CFDictionary)
                let tag = String(label.dropLast(".certificate".count))
                SecItemDelete([kSecClass as String: kSecClassKey,
                               kSecAttrApplicationTag as String: Data(tag.utf8)] as CFDictionary)
            }
        }
    }
}

private func response(_ fields: [String: Any], status: Int = 200) throws -> NativeJoinResponse {
    NativeJoinResponse(statusCode: status, data: try JSONSerialization.data(withJSONObject: fields))
}
