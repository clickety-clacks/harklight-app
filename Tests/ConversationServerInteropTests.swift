import AttentionDomain
import CryptoKit
import HarklightNativeRelay
import Security
import XCTest
@testable import AttentionClientDuoPrototype

/// Opt-in actual-server fixture. Ordinary test runs have no external dependency.
@MainActor
final class ConversationServerInteropTests: XCTestCase {
    func testEnrolledReaderReplaysAndSubmitsExactMixedFilesThroughTheRealServer() async throws {
        let bundle = Bundle(for: Self.self)
        guard let manifestURL = bundle.url(forResource: "conversation-interop", withExtension: "json") else {
            throw XCTSkip("Disposable server fixture was not staged")
        }
        let manifest = try JSONValue.parse(Data(contentsOf: manifestURL))
        XCTAssertEqual(manifest.uniqueValue(named: "fixture_version")?.integerValue, 1)
        XCTAssertEqual(try string(manifest, "host"), "localhost")
        let fixtureID = try string(manifest, "fixture_id")
        let serverCommit = try string(manifest, "server_commit")
        XCTAssertEqual(serverCommit.count, 40)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let ca = try String(contentsOf: resource(bundle, "conversation-interop-ca", "pem"), encoding: .utf8)
        let rootDER = try XCTUnwrap(NativeEnrollmentSettings.certificateDER(from: ca))
        let identity = try importIdentity(Data(contentsOf: resource(bundle, "conversation-interop-client", "p12")))
        let context = ProfileContext(identity: ProfileIdentity(trustedRelayAuthority: ExactText("localhost"),
            personID: ExactText(try string(manifest, "person_id")),
            deviceID: ExactText(try string(manifest, "reader_device_id"))), transportMode: .relay)
        let relayPort = try number(manifest, "relay_port")
        let session = try URLSessionInstallationSession(profile: context,
            relayURL: XCTUnwrap(URL(string: "wss://localhost:\(relayPort)/relay")),
            clientIdentity: TrustedKeychainIdentity(identity), trustedRootDER: rootDER)
        defer { Task { await session.close() } }
        let persistence = FileAttentionStatePersistence(directoryURL: root.appendingPathComponent("State"))
        let domain = try AttentionDomainStore(context: context, persistence: persistence)
        let core = try NativeRelayCore(store: domain, context: context, session: session)
        print("INTEROP_STAGE replay fixture=\(fixtureID) server=\(serverCommit)")
        let ordinaryHigh = try await core.resyncAndDrainOutbox()
        XCTAssertEqual(ordinaryHigh, 1)
        let key = RequestKey(accountScope: context.identity.personID,
            senderID: ExactText(try string(manifest, "sender_id")),
            messageID: ExactText(try string(manifest, "message_id")))
        let binding = ConversationBinding(request: key, revision: try number(manifest, "request_revision"))
        let seed = try domain.conversationSnapshot(context: context)
        XCTAssertEqual(seed.cursor, try number(manifest, "seed_conversation_high"))
        let thread = try XCTUnwrap(seed.threads[key])
        XCTAssertEqual(thread.sessionHandle, ExactText(try string(manifest, "session_handle")))
        XCTAssertEqual(thread.listeningSupport, manifest.uniqueValue(named: "listening_support"))
        let initialID = try string(manifest, "initial_event_id")
        let initial = try XCTUnwrap(thread.turns.first { $0.id.rawValue == initialID })
        XCTAssertEqual(initial.author, .origin)
        XCTAssertTrue(thread.turns.contains { $0.author == .person && $0.text.rawValue == "What should I check first?" })
        XCTAssertTrue(thread.turns.contains { $0.author == .origin && $0.text.rawValue == "Check the exact bytes." && $0.inReplyTo != nil })
        let viewModel = try LivePresentationStore(store: domain, context: context)
        XCTAssertEqual(viewModel.request(for: key)?.title?.rawValue, "Please review the attached file")
        XCTAssertEqual(viewModel.conversation(for: key)?.turns, thread.turns)
        let discoveredEndpoint = try await core.conversationOriginURL()
        let endpoint = try XCTUnwrap(discoveredEndpoint)
        XCTAssertEqual(endpoint.host, "localhost")
        XCTAssertEqual(endpoint.port, Int(try number(manifest, "origin_port")))
        let expectedIncoming = try XCTUnwrap(manifest.uniqueValue(named: "incoming_file"))
        let incoming = try XCTUnwrap(initial.files.first)
        XCTAssertEqual(incoming.name.rawValue, try string(expectedIncoming, "name"))
        XCTAssertEqual(incoming.content, .uploaded(ExactText(try string(expectedIncoming, "upload_id"))))
        XCTAssertEqual(incoming.byteCount, try number(expectedIncoming, "size"))
        XCTAssertEqual(incoming.sha256.rawValue, try string(expectedIncoming, "sha256"))
        print("INTEROP_STAGE fetch-original")
        let downloaded = root.appendingPathComponent(incoming.name.rawValue)
        try await session.fetchConversationFile(incoming, to: downloaded, originURL: endpoint)
        let storage = try ConversationFileStorage(identity: context.identity, root: root)
        try storage.verify(downloaded, for: incoming)
        XCTAssertGreaterThan(incoming.byteCount, 2 * 1024 * 1024)
        let submission = try XCTUnwrap(manifest.uniqueValue(named: "native_submission"))
        var originals: [ConversationFile] = []
        for kind in ["inline", "upload"] {
            let expected = try XCTUnwrap(submission.uniqueValue(named: kind))
            let name = try string(expected, "name")
            let url = try resource(bundle, (name as NSString).deletingPathExtension, (name as NSString).pathExtension)
            let file = try storage.retain(url)
            XCTAssertEqual(file.name.rawValue, name)
            XCTAssertEqual(file.byteCount, try number(expected, "size"))
            XCTAssertEqual(file.sha256.rawValue, try string(expected, "sha256"))
            originals.append(file)
        }
        viewModel.updateConversation(for: key, revision: binding.revision,
            text: try string(submission, "text"), files: originals)
        let operation = try domain.prepareDiscussion(binding, context: context)
        XCTAssertEqual(try domain.prepareDiscussion(binding, context: context), operation)
        print("INTEROP_STAGE submit operation=\(operation.uuidString.lowercased())")
        let result = try await core.submitDiscussion(binding) { file in try storage.fileURL(for: file) }
        guard case let .accepted(turnID) = result else { return XCTFail("Actual server did not accept the saved discussion: \(result)") }
        _ = try await core.resyncAndDrainOutbox()
        let final = try domain.conversationSnapshot(context: context)
        XCTAssertGreaterThan(final.cursor, seed.cursor)
        XCTAssertEqual(try domain.snapshot(context: context).cursor, ordinaryHigh)
        let accepted = try XCTUnwrap(final.threads[key]?.turns.first { $0.id == turnID })
        XCTAssertEqual(accepted.operationID, operation)
        XCTAssertEqual(accepted.text.rawValue, try string(submission, "text"))
        XCTAssertEqual(accepted.files.map(\.name), originals.map(\.name))
        XCTAssertEqual(accepted.files.map(\.sha256), originals.map(\.sha256))
        XCTAssertEqual(accepted.files.map(\.byteCount), originals.map(\.byteCount))
        guard accepted.files.count == 2 else { return XCTFail("The accepted entry lost a selected file") }
        guard case .inline = accepted.files[0].content, case .uploaded = accepted.files[1].content else {
            return XCTFail("Whole-file inline/upload boundary was not preserved")
        }
        XCTAssertNil(final.threads[key]?.drafts[binding.revision])
        let legacy = try domain.snapshot(context: context)
        XCTAssertTrue(legacy.intents.isEmpty)
        XCTAssertTrue(legacy.outbox.isEmpty)
        let restored = try AttentionDomainStore(context: context, persistence: persistence)
        let restoredConversation = try restored.conversationSnapshot(context: context)
        XCTAssertEqual(restoredConversation.cursor, final.cursor)
        XCTAssertEqual(restoredConversation.threads, final.threads)
        XCTAssertEqual(try restored.snapshot(context: context).cursor, ordinaryHigh)
        print("INTEROP_COMPLETE fixture=\(fixtureID) operation=\(operation.uuidString.lowercased()) ordinary=\(ordinaryHigh) conversation=\(final.cursor)")
        await session.close()
    }

    private func resource(_ bundle: Bundle, _ name: String, _ ext: String) throws -> URL {
        try XCTUnwrap(bundle.url(forResource: name, withExtension: ext), "Missing disposable fixture resource \(name).\(ext)")
    }
    private func string(_ value: JSONValue, _ name: String) throws -> String {
        try XCTUnwrap(value.uniqueValue(named: name)?.stringValue?.rawValue, "Missing fixture \(name)")
    }
    private func number(_ value: JSONValue, _ name: String) throws -> UInt64 {
        let integer = try XCTUnwrap(value.uniqueValue(named: name)?.integerValue, "Missing fixture \(name)")
        return try XCTUnwrap(UInt64(exactly: integer))
    }
    private func importIdentity(_ bytes: Data) throws -> SecIdentity {
        var items: CFArray?
        let status = SecPKCS12Import(bytes as CFData,
            [kSecImportExportPassphrase as String: "public-fixture-only"] as CFDictionary, &items)
        XCTAssertEqual(status, errSecSuccess)
        let first = try XCTUnwrap((items as? [[String: Any]])?.first)
        let value = try XCTUnwrap(first[kSecImportItemIdentity as String])
        return value as! SecIdentity
    }
}
