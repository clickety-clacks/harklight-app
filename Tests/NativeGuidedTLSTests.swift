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
    // All connection ownership is serialized on queue, including close().
    private var connections: [NWConnection] = []
    private var requestWasReceived = false
    var receivedRequest: Bool { queue.sync { requestWasReceived } }

    init(expectedDevice: String?, replyBody: Data = Data("{\"state\":\"reachable\"}".utf8),
         advertiseSize: Bool = true, redirectTo: URL? = nil) throws {
        self.replyBody = replyBody
        self.advertiseSize = advertiseSize
        self.redirectTo = redirectTo
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
                connection.start(queue: queue)
                receive(connection, buffer: Data())
            }
            listener.start(queue: queue)
        }
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, done, error in
            guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
            let next = buffer + data
            guard next.count <= 32 * 1024 else { connection.cancel(); return }
            if let boundary = next.range(of: Data("\r\n\r\n".utf8)),
               let header = String(data: next[..<boundary.lowerBound], encoding: .utf8) {
                let length = header.components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") })
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                if next.count - boundary.upperBound >= length {
                    requestWasReceived = true
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
