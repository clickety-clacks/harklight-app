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
        defer {
            for record in [original, replacement] {
                SecItemDelete([kSecClass as String: kSecClassCertificate,
                               kSecAttrLabel as String: record.identityLabel] as CFDictionary)
                let namespace = service + "." + record.deviceLabel
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

    func testReadOnlyDraftStatusDoesNotCallUncertainOrAcceptedSubmissionUndelivered() throws {
        let locale = Locale(identifier: "en")
        XCTAssertEqual(String(localized: ConversationDraftPresentationText.readOnlyHeading, locale: locale),
                       "Saved discussion draft")
        XCTAssertFalse(String(localized: ConversationDraftPresentationText.readOnlyHeading, locale: locale)
            .contains("not delivered"))

        let unknown = try XCTUnwrap(ConversationDraftPresentationText.status(for: .outcomeUnknown(UUID())))
        XCTAssertEqual(String(localized: unknown, locale: locale), "Submission unconfirmed · saved draft retained")
        let accepted = try XCTUnwrap(ConversationDraftPresentationText.status(for:
            .acceptedPendingReplay(operation: UUID(), turn: ExactText("saved-turn"))))
        XCTAssertEqual(String(localized: accepted, locale: locale), "Accepted · awaiting synchronized history")
        XCTAssertNil(ConversationDraftPresentationText.status(for: .saved))
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
