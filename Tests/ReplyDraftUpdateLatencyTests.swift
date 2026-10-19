import XCTest
@testable import AttentionClientDuoPrototype
import AttentionDomain

final class ReplyDraftUpdateLatencyTests: XCTestCase {
    @MainActor
    func testApplicationReplyDraftUpdateLatencyFor256Keystrokes() throws {
        let fixtures = try FixtureSet.loadBundled(from: Bundle(for: ReplyDraftUpdateLatencyTests.self))
        let fixture = try XCTUnwrap(fixtures.requests.first(where: { $0.key.messageID == ExactText("facilities-01") }))
        guard case let .sender(document) = fixture.interface else {
            return XCTFail("Expected the reply fixture's sender document.")
        }
        let input = try XCTUnwrap(document.inputs.first(where: { if case .text = $0.kind { return true }; return false }))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "reply-draft-latency-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let identity = ProfileIdentity(trustedRelayAuthority: ExactText("fixture-only:test"),
                                       personID: fixtures.accountScope,
                                       deviceID: ExactText("device-a"))
        let context = ProfileContext(identity: identity, transportMode: .fixture)
        let persistence = FileAttentionStatePersistence(directoryURL: directory)
        let store = try makeStore(fixtures: fixtures, context: context, persistence: persistence)
        let editor = try LivePresentationStore(localFixtureStore: store, context: context)

        var reply = ""
        let started = ProcessInfo.processInfo.systemUptime
        for _ in 0..<256 {
            reply.append("a")
            editor.updateText(reply, input: input.id, action: nil, for: fixture.key)
        }
        let elapsedMilliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1_000

        let measurement = """
        scenario=application reply draft update path
        characters=\(reply.count)
        elapsed_ms=\(String(format: "%.2f", elapsedMilliseconds))
        average_ms_per_character=\(String(format: "%.4f", elapsedMilliseconds / Double(reply.count)))
        """
        let attachment = XCTAttachment(data: Data(measurement.utf8), uniformTypeIdentifier: "public.plain-text")
        attachment.name = "reply-draft-update-latency"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func makeStore(fixtures: FixtureSet,
                           context: ProfileContext,
                           persistence: any AttentionStatePersistence) throws -> AttentionDomainStore {
        let store = try AttentionDomainStore(context: context, persistence: persistence)
        let requests = fixtures.requests.map { request in
            StoredRequest(key: RequestKey(accountScope: context.identity.personID,
                                          senderID: request.key.senderID,
                                          messageID: request.key.messageID),
                          originalPayload: request.originalPayload)
        }
        try store.registerFixtureRequests(requests, context: context)
        return store
    }
}
